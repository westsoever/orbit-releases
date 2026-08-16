import Foundation

/// A `users` row as served by `GET /api/user/<id>` and returned by `POST /api/users`. The
/// GRDB record conformances are gone with the app's database handle (plan 51 decision D1);
/// the `CodingKeys` below are unchanged, and the daemon emits exactly those keys.
struct OrbitUser: Codable, Sendable {
    let id: String
    let email: String
    let displayName: String
    let createdAt: String
    var cloudUserId: String?

    enum CodingKeys: String, CodingKey {
        case id, email
        case displayName = "display_name"
        case createdAt = "created_at"
        case cloudUserId = "cloud_user_id"
    }
}

struct OrbitUserSession: Codable, Sendable {
    let userId: String
    let email: String
    let signedInAt: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case email
        case signedInAt = "signed_in_at"
    }
}

enum UserSessionError: LocalizedError {
    case invalidEmail
    case invalidDisplayName
    case userAlreadyExists
    case persistenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidEmail: return "Enter a valid email address."
        case .invalidDisplayName: return "Enter your name."
        case .userAlreadyExists: return "An account with this email already exists on this Mac."
        case .persistenceFailed(let detail): return detail
        }
    }
}

@MainActor
@Observable
final class UserSessionService {
    static let shared = UserSessionService()

    private(set) var currentSession: OrbitUserSession?
    private(set) var currentUser: OrbitUser?

    /// Plan 51 decision D1: `users` lives in the SQLCipher-encrypted store that only the
    /// daemon can open, so both the read and the sign-up write go over localhost HTTP. Its
    /// own client instance rather than `AppViewModel.bridge` because this is a singleton
    /// that exists before the view model does; `OrbitBridgeClient` holds no per-instance
    /// state beyond its last `/api/status` poll.
    @ObservationIgnored private let bridge = OrbitBridgeClient()

    var isSignedIn: Bool { currentSession != nil }

    private init() {
        // `isSignedIn` gates the whole window, so this singleton is built on the first frame —
        // the earliest hook the app reliably reaches. Inert unless the dev env vars are set;
        // see `UserAuthService.runTokenStoreDiagnosticsIfEnabled()` (plan 53 Phase 5).
        UserAuthService.shared.runTokenStoreDiagnosticsIfEnabled()
        reloadFromDisk()
    }

    /// The session file is still read synchronously — `isSignedIn` gates the whole window and
    /// must be correct on the first frame. Only the user *row* is fetched asynchronously, so
    /// `currentUser` (display name, email) fills in a round-trip later.
    func reloadFromDisk() {
        currentSession = Self.loadSessionFile()
        currentUser = nil
        guard let session = currentSession else { return }
        Task { @MainActor [bridge] in
            guard let user = try? await bridge.fetchUser(id: session.userId) else { return }
            // Ignore a late reply that lost a race with a sign-out or a different sign-in.
            guard self.currentSession?.userId == user.id else { return }
            self.currentUser = user
        }
    }

    /// True only when the local `users` row carries a relay account id. §0.5A: "has a cloud
    /// account" is `cloud_user_id IS NOT NULL` and **never** an email test — a local-only
    /// identity has a synthetic `@orbit.local` address, which is a real address in the
    /// column, just an unroutable one.
    var hasCloudAccount: Bool {
        currentUser?.cloudUserId?.isEmpty == false
    }

    /// Plan 53 Phase 4 — the local half of magic-link sign-in.
    ///
    /// `signUp(email:displayName:password:)` is gone with the relay routes it called. It
    /// would also now be wrong: since Phase 1 the daemon mints the local identity itself at
    /// startup, so signing in must **link** that existing row rather than insert a second
    /// one and orphan everything already captured against the first.
    ///
    /// Refuses without an active session rather than creating one: minting users stays in
    /// exactly one place (daemon startup), per Phase 1's anti-pattern guard.
    @discardableResult
    func linkCloudAccount(cloudUserId: String) async throws -> OrbitUser {
        guard let session = currentSession else {
            throw UserSessionError.persistenceFailed(
                "orbit has not finished starting up. Wait for the background service, then sign in."
            )
        }
        let user: OrbitUser
        do {
            user = try await bridge.linkUserCloudAccount(
                userId: session.userId,
                cloudUserId: cloudUserId
            )
        } catch {
            throw UserSessionError.persistenceFailed(error.localizedDescription)
        }
        currentUser = user
        return user
    }

    /// The sign-out contract (plan 53 Phase 5, risk R4).
    ///
    /// Signing out **revokes credentials, and only credentials**:
    ///
    /// | Removed | Kept |
    /// |---|---|
    /// | `~/.orbit/session.json` | the local `users` row, including `cloud_user_id` |
    /// | the relay session token + expiry, from the Keychain *and* `UserDefaults` | every captured atom, event and task |
    /// | the Cloud AI device token, from the Keychain *and* `~/.orbit/cloud.json` | `~/.orbit/orbit.db` in full |
    ///
    /// Before Phase 5 this deleted `session.json` and nothing else, so a signed-out app still
    /// held a live relay bearer token (R4). It must **never** delete the `users` row or any
    /// captured data: signing out of the cloud returns you to local-only — since Phase 1 the
    /// daemon keeps a local identity with no account at all — it does not erase your context.
    func signOut() throws {
        try? FileManager.default.removeItem(at: OrbitPaths.sessionURL)
        UserAuthService.shared.clearSession()
        CloudAIService.shared.clearDeviceCredentials()
        currentSession = nil
        currentUser = nil
    }

    private func persistSession(userId: String, email: String) throws {
        try OrbitPaths.ensureOrbitDirectoryExists()
        let session = OrbitUserSession(
            userId: userId,
            email: email,
            signedInAt: ISO8601DateFormatter().string(from: Date())
        )
        let data = try JSONEncoder().encode(session)
        try data.write(to: OrbitPaths.sessionURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: OrbitPaths.sessionURL.path)
    }

    nonisolated private static func loadSessionFile() -> OrbitUserSession? {
        guard let data = try? Data(contentsOf: OrbitPaths.sessionURL) else { return nil }
        return try? JSONDecoder().decode(OrbitUserSession.self, from: data)
    }

    /// Session user id from disk — safe to call outside `@MainActor`. The daemon reads the
    /// same file (`orbit.storage.session.get_active_user_id()`) to scope its own queries.
    nonisolated static func loadSessionUserId() -> String? {
        loadSessionFile()?.userId
    }
}
