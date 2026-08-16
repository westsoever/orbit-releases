import AppKit
import Foundation
import Security

enum CloudAIError: LocalizedError {
    case registrationFailed(String)
    case persistenceFailed(String)
    case invalidRelayURL

    var errorDescription: String? {
        switch self {
        case .registrationFailed(let message): return message
        case .persistenceFailed(let message): return message
        case .invalidRelayURL: return "Invalid relay URL."
        }
    }
}

struct CloudAIConfig: Codable, Sendable {
    let deviceToken: String
    let relayBaseURL: String

    enum CodingKeys: String, CodingKey {
        case deviceToken = "device_token"
        case relayBaseURL = "relay_base_url"
    }
}

struct CloudRegisterResponse: Decodable {
    let deviceToken: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case deviceToken = "device_token"
        case expiresAt = "expires_at"
    }
}

/// Registers devices with the Orbit Cloud AI relay and writes ``~/.orbit/cloud.json`` for the daemon.
final class CloudAIService: @unchecked Sendable {
    static let shared = CloudAIService()

    private let keychainService = "com.orbit.access.cloud"
    private let installIDKey = "orbit.install_id"
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Override via ``ORBIT_RELAY_URL`` env; defaults to local relay for development.
    static var defaultRelayURL: URL {
        if let raw = ProcessInfo.processInfo.environment["ORBIT_RELAY_URL"],
           let url = URL(string: raw) {
            return url
        }
        return URL(string: "http://127.0.0.1:8080")!
    }

    var installID: UUID {
        if let stored = UserDefaults.standard.string(forKey: installIDKey),
           let uuid = UUID(uuidString: stored) {
            return uuid
        }
        let fresh = UUID()
        UserDefaults.standard.set(fresh.uuidString, forKey: installIDKey)
        return fresh
    }

    func isEnabled() -> Bool {
        guard let config = try? loadPersistedConfig() else { return false }
        return !config.deviceToken.isEmpty
    }

    func hasBYOK() -> Bool {
        let url = OrbitPaths.envFileURL
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.contains("OPENROUTER_API_KEY=") &&
            text.split(separator: "\n").contains { line in
                line.hasPrefix("OPENROUTER_API_KEY=") &&
                    !line.dropFirst("OPENROUTER_API_KEY=".count).trimmingCharacters(in: .whitespaces).isEmpty
            }
    }

    func hasLocalLLMConfigured() -> Bool {
        LLMPreferencesService.shared.isLocalConfigured()
    }

    func hasLocalLLM() -> Bool {
        hasLocalLLMConfigured()
    }

    func register() async throws -> CloudAIConfig {
        let relayURL = Self.defaultRelayURL
        var request = URLRequest(url: relayURL.appendingPathComponent("/v1/devices/register"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sessionToken = UserAuthService.shared.sessionToken {
            request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: String] = [
            "install_id": installID.uuidString,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1",
        ]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudAIError.registrationFailed("Invalid response from relay.")
        }
        guard http.statusCode == 201 else {
            let raw = Self.errorMessage(from: data) ?? "HTTP \(http.statusCode)"
            throw CloudAIError.registrationFailed(ChatErrorFormatter.relayRegistrationMessage(raw))
        }

        let decoded = try JSONDecoder().decode(CloudRegisterResponse.self, from: data)
        let config = CloudAIConfig(deviceToken: decoded.deviceToken, relayBaseURL: relayURL.absoluteString)
        try persist(config)
        return config
    }

    func disable() throws {
        clearDeviceCredentials()
    }

    /// Drops every copy of the device token: the Keychain item and `~/.orbit/cloud.json`,
    /// which is the copy the daemon actually reads.
    ///
    /// Plan 53 Phase 5 sign-out contract. Deleting only the Keychain item would be theatre —
    /// `loadPersistedConfig()` reads `cloud.json`, so the credential would still work. This
    /// removes credentials only: **no `users` row, no captured data, no database.** Signing
    /// out returns the app to local-only; it does not erase context.
    func clearDeviceCredentials() {
        try? FileManager.default.removeItem(at: OrbitPaths.cloudConfigURL)
        // Order matters: the Keychain account *is* the install id, so the item has to go
        // before the id that names it, or it is orphaned beyond reach.
        deleteKeychainToken()
        // Rotate the install id, or this Mac can never enable Cloud AI again. Measured against
        // the local relay: `POST /v1/devices/register` answers **409
        // `install_id_already_registered`** for an id it has seen before — a permanent
        // uniqueness rule in `store.py:215`, not a daily limit. Dropping the only copies of the
        // device token while keeping the id it was minted for leaves the app with no token and
        // no way to obtain one. (This also fixes the same dead end in `disable()`, which has
        // always deleted `cloud.json` without rotating.) Nothing else reads `orbit.install_id`.
        UserDefaults.standard.removeObject(forKey: installIDKey)
    }

    func persist(_ config: CloudAIConfig) throws {
        try OrbitPaths.ensureOrbitDirectoryExists()
        let data = try JSONEncoder().encode(config)
        try data.write(to: OrbitPaths.cloudConfigURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: OrbitPaths.cloudConfigURL.path
        )
        saveKeychainToken(config.deviceToken)
    }

    func loadPersistedConfig() throws -> CloudAIConfig? {
        let url = OrbitPaths.cloudConfigURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CloudAIConfig.self, from: data)
    }

    func openOrbitDirectory() {
        NSWorkspace.shared.open(OrbitPaths.orbitDirectory)
    }

    /// Best-effort, and deliberately no longer throwing (plan 53 Phase 5, risk R1).
    ///
    /// This used to abort `persist(_:)` — and therefore `register()` — on any status but
    /// `errSecSuccess`, which turned a *successful* device registration into a user-facing
    /// failure. `cloud.json` (already written, 0600) is the copy every reader actually uses:
    /// nothing in the app or the daemon has ever read this token back out of the Keychain.
    ///
    /// Measured in the real ad-hoc-signed sandboxed bundle, `SecItemAdd` **succeeds** here — the
    /// item lands in the login keychain (verified with `security find-generic-password -s
    /// com.orbit.access.cloud`). The failure this now survives is the one that does happen:
    /// after a rebuild the ad-hoc identity changes, the item's ACL no longer matches, and
    /// access comes back `errSecAuthFailed (-25293)`. The status is still checked —
    /// `OrbitKeychain` logs one line per distinct status per process.
    private func saveKeychainToken(_ token: String) {
        OrbitKeychain.write(
            service: keychainService, account: installID.uuidString, value: token
        )
    }

    private func deleteKeychainToken() {
        OrbitKeychain.delete(service: keychainService, account: installID.uuidString)
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8)
        }
        if let detail = json["detail"] as? [String: Any], let error = detail["error"] as? String {
            return error
        }
        if let error = json["error"] as? String {
            return error
        }
        return nil
    }
}
