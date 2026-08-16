import Foundation
import OSLog
import Security

/// Dev-only echo of the auth/Keychain diagnostics to stderr, enabled by
/// `ORBIT_AUTH_DEBUG_TOKEN_STORE`. Inert — and therefore silent — in every shipped bundle.
///
/// It exists because `OSLog` turned out to be unusable as *evidence* here: while verifying
/// Phase 5, `log show`/`log stream` dropped this process's `Logger.notice` lines even though
/// the code demonstrably ran (the `SecItem*` traces for the same instant were there). Log
/// lines you cannot reliably read back cannot verify anything, so the assertions the plan
/// asks for are echoed to a channel the launching shell owns.
enum OrbitAuthDebugLog {
    static var isEnabled: Bool {
        guard let raw = ProcessInfo.processInfo.environment["ORBIT_AUTH_DEBUG_TOKEN_STORE"] else {
            return false
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "1" || value == "true" || value == "yes" || value == "on"
    }

    static func echo(_ line: String) {
        guard isEnabled else { return }
        FileHandle.standardError.write(Data("[orbit-auth] \(line)\n".utf8))
    }
}

/// The app's only Keychain wrapper (plan 53 Phase 5).
///
/// Before this, the app had `SecItemAdd` and `SecItemDelete` and nothing else
/// (`CloudAIService.saveKeychainToken`/`deleteKeychainToken`) — §0.4 anti-pattern 2. The read
/// path here is new code, so it mirrors the existing write query dictionary **exactly**,
/// adding only `kSecReturnData` and `kSecMatchLimit`. There is no `SecItemUpdate`: writes are
/// delete-then-add, which is the idiom `saveKeychainToken` already established.
///
/// **Risk R1 is the reason every call returns a status instead of throwing.** The app is
/// sandboxed (`OrbitAccessApp.entitlements`) with no `keychain-access-groups`, and it is
/// ad-hoc codesigned (`codesign --force --sign -`) — the configuration R1 expected to fail with
/// `errSecMissingEntitlement (-34018)`.
///
/// **Measured, in the real installed bundle: it does not.** Add, delete and read all succeed;
/// the items land in the login keychain and read back across a quit and relaunch. `-34018`
/// belongs to the *data-protection* keychain, which these queries never touch — without
/// `kSecUseDataProtectionKeychain` a generic password goes to the legacy file-based keychain,
/// which has no entitlement requirement.
///
/// What does fail is narrower and was measured too: an item's ACL is bound to the code identity
/// that created it, and **ad-hoc signing produces a new identity on every rebuild**, so the
/// next build reads its own item back as `errSecAuthFailed (-25293)`. That is a dev-loop
/// condition, not a shipping one — a stable Developer ID keeps the ACL valid — but it is
/// exactly why the fallback has to exist. Callers treat any status other than `errSecSuccess`
/// as "the Keychain is not usable right now" and fall back to `UserDefaults`.
/// **A Keychain failure must never block sign-in.**
enum OrbitKeychain {
    enum ReadResult {
        /// The item exists and decoded to a non-empty string.
        case found(String)
        /// `errSecItemNotFound`, or an item that decoded to nothing. Not an error.
        case missing
        /// Any other status. The Keychain is unusable; the caller falls back.
        case failed(OSStatus)
    }

    private static let logger = Logger(subsystem: "com.orbit.access", category: "Keychain")

    private static let lock = NSLock()
    private static var loggedFailures: Set<String> = []

    /// Dev-only fault injection for R1, which is otherwise unreproducible on a machine where
    /// the Keychain happens to work. Unset (the default, and what a shipped bundle has) this
    /// is inert — `run_orbit_access_app.sh` never writes it into `LSEnvironment`.
    ///
    /// `ORBIT_KEYCHAIN_FAULT=1` forces `errSecMissingEntitlement`; any other integer forces
    /// that literal `OSStatus`, so other failure modes can be rehearsed too.
    static var injectedFailureStatus: OSStatus? {
        guard let raw = ProcessInfo.processInfo.environment["ORBIT_KEYCHAIN_FAULT"] else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        case "", "0", "false", "no", "off": return nil
        case "1", "true", "yes", "on": return errSecMissingEntitlement
        default: return Int32(value).map { OSStatus($0) } ?? errSecMissingEntitlement
        }
    }

    static var isFaultInjected: Bool { injectedFailureStatus != nil }

    /// Orbit-local sentinel for "our own watchdog fired, the Keychain never answered". Well
    /// outside every Apple `OSStatus` range, so it cannot be confused with a real status.
    /// See ``perform(_:)``.
    private static let watchdogStatus: OSStatus = -99001

    /// How long any single Keychain call may take before we give up on it.
    private static let callTimeout: TimeInterval = 2.0

    static func read(service: String, account: String) -> ReadResult {
        if let forced = injectedFailureStatus {
            logFailureOnce("read", service: service, account: account, status: forced)
            return .failed(forced)
        }
        let outcome: (OSStatus, Data?) = perform { () -> (OSStatus, Data?) in
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            return (status, item as? Data)
        } ?? (watchdogStatus, nil)
        switch outcome.0 {
        case errSecSuccess:
            guard let data = outcome.1,
                  let text = String(data: data, encoding: .utf8),
                  !text.isEmpty
            else { return .missing }
            return .found(text)
        case errSecItemNotFound:
            return .missing
        default:
            logFailureOnce("read", service: service, account: account, status: outcome.0)
            return .failed(outcome.0)
        }
    }

    /// Delete-then-add, because there is no `SecItemUpdate` precedent in this app.
    @discardableResult
    static func write(service: String, account: String, value: String) -> OSStatus {
        if let forced = injectedFailureStatus {
            logFailureOnce("write", service: service, account: account, status: forced)
            return forced
        }
        _ = delete(service: service, account: account)
        let status = perform { () -> OSStatus in
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecValueData as String: Data(value.utf8),
            ]
            return SecItemAdd(query as CFDictionary, nil)
        } ?? watchdogStatus
        if status != errSecSuccess {
            logFailureOnce("write", service: service, account: account, status: status)
        }
        return status
    }

    @discardableResult
    static func delete(service: String, account: String) -> OSStatus {
        if let forced = injectedFailureStatus { return forced }
        let status = perform { () -> OSStatus in
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            return SecItemDelete(query as CFDictionary)
        } ?? watchdogStatus
        if status != errSecSuccess, status != errSecItemNotFound {
            logFailureOnce("delete", service: service, account: account, status: status)
        }
        return status
    }

    /// Runs one `SecItem*` call off the calling thread, under a watchdog, with the legacy
    /// keychain's interaction UI turned off.
    ///
    /// **This is not defensive decoration — it is a fix for an observed hang.** Measured during
    /// Phase 5 verification: `SecItemCopyMatching` for a generic password goes through the
    /// *legacy* file-based keychain on macOS, and the item's ACL is bound to the code signature
    /// that created it. This app is ad-hoc signed, so **every rebuild produces a new identity**
    /// and the next read no longer matches the ACL. `securityd` then raises an access prompt —
    /// and because the read happens while the SwiftUI `App.init()` is still running, there is no
    /// UI to show it against. The sampled stack was `App.init → UserSessionService.init →
    /// sessionToken → SecItemCopyMatching → SecKeychainItemCopyContent`, wedged on the main
    /// thread with a `SecurityAgent` alive and no visible dialog: a dead app with a blank screen.
    ///
    /// Two guards, because either alone is incomplete:
    /// 1. `SecKeychainSetUserInteractionAllowed(false)` makes the legacy keychain return
    ///    `errSecInteractionNotAllowed` instead of prompting. It is process-wide, so it is set
    ///    for the duration of the call and restored immediately.
    /// 2. A watchdog, because (1) is deprecated API and process-wide state another framework
    ///    can flip. On expiry the caller gets `errSecTimeout` and falls back to `UserDefaults`;
    ///    the abandoned worker thread finishes on its own.
    /// Returns `nil` if the watchdog fired.
    private static func perform<T: Sendable>(_ work: @escaping @Sendable () -> T) -> T? {
        let box = ResultBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var wasAllowed: DarwinBoolean = true
            let restorable = getInteractionAllowed?(&wasAllowed) == errSecSuccess
            _ = setInteractionAllowed?(false)
            let value = work()
            _ = setInteractionAllowed?(DarwinBoolean(restorable ? wasAllowed.boolValue : true))
            box.value = value
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + callTimeout) == .success else { return nil }
        return box.value
    }

    private typealias SetInteractionAllowedFn = @convention(c) (DarwinBoolean) -> OSStatus
    private typealias GetInteractionAllowedFn = @convention(c) (UnsafeMutablePointer<DarwinBoolean>) -> OSStatus

    /// `SecKeychainSetUserInteractionAllowed` / `SecKeychainGetUserInteractionAllowed`,
    /// resolved at runtime instead of called directly.
    ///
    /// Both are deprecated, and a direct call warns not only here but at every caller up the
    /// chain (`@available` propagates the warning rather than absorbing it) — this app builds
    /// warning-clean and should stay that way. Resolving them dynamically also degrades
    /// safely: they belong to the legacy `SecKeychain` API, so if Apple ever removes them the
    /// toggle simply becomes a no-op and the watchdog below still holds the guarantee.
    private static let setInteractionAllowed: SetInteractionAllowedFn? = {
        guard let symbol = dlsym(
            UnsafeMutableRawPointer(bitPattern: -2), "SecKeychainSetUserInteractionAllowed"
        ) else { return nil }
        return unsafeBitCast(symbol, to: SetInteractionAllowedFn.self)
    }()

    private static let getInteractionAllowed: GetInteractionAllowedFn? = {
        guard let symbol = dlsym(
            UnsafeMutableRawPointer(bitPattern: -2), "SecKeychainGetUserInteractionAllowed"
        ) else { return nil }
        return unsafeBitCast(symbol, to: GetInteractionAllowedFn.self)
    }()

    /// Hand-off slot for ``perform(_:)``. Written by the worker before it signals, read by the
    /// waiter after — the semaphore is the ordering, so no further locking is needed.
    private final class ResultBox<T>: @unchecked Sendable {
        var value: T?
    }

    /// **One line per distinct `OSStatus` per process.** R1 asks for a single line, and
    /// `sessionToken` is read on every relay call, so keying the dedup on the status (rather
    /// than on the call site) keeps a broken Keychain to exactly one line while still
    /// surfacing a genuinely different second failure mode.
    private static func logFailureOnce(_ operation: String, service: String, account: String, status: OSStatus) {
        let key = "\(status)"
        lock.lock()
        let isNew = loggedFailures.insert(key).inserted
        lock.unlock()
        guard isNew else { return }
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "no description"
        OrbitAuthDebugLog.echo(
            "keychain \(operation) failed for \(service)/\(account): OSStatus \(status) (\(detail)) — falling back to UserDefaults"
        )
        logger.error(
            """
            Keychain \(operation, privacy: .public) failed for \
            \(service, privacy: .public)/\(account, privacy: .public): \
            OSStatus \(status, privacy: .public) (\(detail, privacy: .public)). \
            Falling back to UserDefaults — sign-in is unaffected.
            """
        )
    }
}

enum UserAuthError: LocalizedError {
    case registrationFailed(String)
    case invalidRelayURL
    /// Raised only if a caller reaches the relay while `ORBIT_CLOUD_AUTH_ENABLED` is off.
    /// The UI never offers sign-in in that state, so this is a programming-error backstop.
    case cloudAuthDisabled

    var errorDescription: String? {
        switch self {
        case .registrationFailed(let message): return message
        case .invalidRelayURL: return "Invalid relay URL."
        case .cloudAuthDisabled: return "Cloud accounts are not enabled in this build."
        }
    }
}

/// `POST /v1/auth/magic-link/verify` → 200. Plan 53 Phase 3 replaced the signup/login
/// bodies with this one; `expires_at` is new and, unlike before (§0.4 anti-pattern 10),
/// it is decoded and retained.
struct AuthSessionResponse: Decodable {
    let userId: String
    let sessionToken: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case sessionToken = "session_token"
        case expiresAt = "expires_at"
    }
}

/// Optional cloud identity via orbit-relay, using the magic-link (6-digit code) flow.
///
/// Plan 53 Phase 4. Password auth is gone on both sides: `POST /v1/auth/signup` and
/// `POST /v1/auth/login` were deleted from the relay in Phase 3, and the two methods that
/// called them are deleted here. What replaces them is a two-step exchange —
/// `requestMagicLink` (always 202, so it never reveals whether an address has an account)
/// then `verifyMagicLink`, which mints exactly the session token `POST /v1/devices/register`
/// already resolves, so Cloud AI registration keeps working unchanged.
///
/// Decision D5: the code is **typed by the user**, not opened from a link. There is
/// deliberately no URL scheme, no `CFBundleURLTypes` and no `onOpenURL` anywhere in the app.
final class UserAuthService: @unchecked Sendable {
    static let shared = UserAuthService()

    private let session: URLSession

    /// Plan 53 Phase 5. The Keychain is the store of record for both values; the identically
    /// named `UserDefaults` keys survive only as the R1 fallback and as the migration source.
    private static let keychainService = "com.orbit.access.auth"
    private static let sessionTokenKey = "orbit.auth.session_token"
    private static let sessionExpiresAtKey = "orbit.auth.session_expires_at"

    private let migrationLock = NSLock()
    private var didAttemptMigration = false

    private static let logger = Logger(subsystem: "com.orbit.access", category: "Auth")

    init(session: URLSession = .shared) {
        self.session = session
    }

    private var relayURL: URL {
        CloudAIService.defaultRelayURL
    }

    /// Cloud sign-in is dark until the relay is deployed (decision D4, risk R5). Read from
    /// the environment exactly as `CloudAIService.defaultRelayURL` reads `ORBIT_RELAY_URL`
    /// (`CloudAIService.swift:51-58`) — same `ProcessInfo` lookup, same
    /// fall-through-to-default shape. **Default off.** When off, no sign-in UI is offered
    /// anywhere; the app is a fully working local-only product (decision D2).
    ///
    /// A launched `.app` gets this from `LSEnvironment` in its `Info.plist`, which
    /// `scripts/run_orbit_access_app.sh` injects — exporting it in a shell only reaches
    /// `swift run` (risk R2).
    static var isCloudAuthEnabled: Bool {
        if let raw = ProcessInfo.processInfo.environment["ORBIT_CLOUD_AUTH_ENABLED"] {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return value == "1" || value == "true" || value == "yes" || value == "on"
        }
        return false
    }

    /// Ask the relay to mail a 6-digit code. Always 202 for any well-formed address, known
    /// or unknown — the caller must not treat success as "this account exists".
    func requestMagicLink(email: String) async throws {
        guard Self.isCloudAuthEnabled else { throw UserAuthError.cloudAuthDisabled }
        var request = URLRequest(url: relayURL.appendingPathComponent("/v1/auth/magic-link/request"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Explicit, and shorter than URLSession's 60s default: an unreachable relay must
        // surface a readable error rather than leave a spinner running for a minute.
        request.timeoutInterval = 15
        let body: [String: String] = ["email": email]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UserAuthError.registrationFailed("Invalid response from relay.")
        }
        guard http.statusCode == 202 else {
            let message = Self.errorMessage(from: data) ?? "HTTP \(http.statusCode)"
            throw UserAuthError.registrationFailed(message)
        }
    }

    /// Exchange the typed code for a session. Returns the **cloud** user id, which the
    /// caller writes onto the local `users` row via `POST /api/user/link`.
    func verifyMagicLink(email: String, code: String) async throws -> String {
        guard Self.isCloudAuthEnabled else { throw UserAuthError.cloudAuthDisabled }
        var request = URLRequest(url: relayURL.appendingPathComponent("/v1/auth/magic-link/verify"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        let body: [String: String] = ["email": email, "code": code]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UserAuthError.registrationFailed("Invalid response from relay.")
        }
        guard http.statusCode == 200 else {
            let message = Self.errorMessage(from: data) ?? "HTTP \(http.statusCode)"
            throw UserAuthError.registrationFailed(message)
        }

        let decoded = try JSONDecoder().decode(AuthSessionResponse.self, from: data)
        persistSession(token: decoded.sessionToken, expiresAt: decoded.expiresAt)
        return decoded.userId
    }

    // MARK: - Token storage (plan 53 Phase 5)

    /// Keychain first, `UserDefaults` only if the Keychain refused the write.
    ///
    /// Deliberately non-throwing: the caller has already exchanged a valid code with the relay
    /// at this point, and R1 says a Keychain failure must not turn a successful sign-in into a
    /// failed one. The worst case is the pre-Phase-5 behaviour, which is what shipped in
    /// Phase 4.
    private func persistSession(token: String, expiresAt: String) {
        let tokenStatus = OrbitKeychain.write(
            service: Self.keychainService, account: Self.sessionTokenKey, value: token
        )
        let expiryStatus = OrbitKeychain.write(
            service: Self.keychainService, account: Self.sessionExpiresAtKey, value: expiresAt
        )

        guard tokenStatus == errSecSuccess, expiryStatus == errSecSuccess else {
            // Never leave half a pair behind: a Keychain token with a `UserDefaults` expiry
            // would read back as two different sessions.
            OrbitKeychain.delete(service: Self.keychainService, account: Self.sessionTokenKey)
            OrbitKeychain.delete(service: Self.keychainService, account: Self.sessionExpiresAtKey)
            UserDefaults.standard.set(token, forKey: Self.sessionTokenKey)
            UserDefaults.standard.set(expiresAt, forKey: Self.sessionExpiresAtKey)
            markMigrationAttempted()
            return
        }

        // The Keychain holds it now, so no plaintext copy may survive.
        UserDefaults.standard.removeObject(forKey: Self.sessionTokenKey)
        UserDefaults.standard.removeObject(forKey: Self.sessionExpiresAtKey)
        markMigrationAttempted()
    }

    /// One-time move of a Phase 4 session out of `UserDefaults`.
    ///
    /// Runs at most once per process, on the first read. A Keychain value always wins — if one
    /// exists we never look at `UserDefaults`, so a stale plaintext copy cannot resurrect an
    /// older session. If the Keychain refuses the write, the plaintext copy stays exactly where
    /// it is and the user notices nothing.
    private func migrateLegacyDefaultsIfNeeded() {
        migrationLock.lock()
        defer { migrationLock.unlock() }
        guard !didAttemptMigration else { return }
        didAttemptMigration = true

        let defaults = UserDefaults.standard
        guard let legacyToken = defaults.string(forKey: Self.sessionTokenKey), !legacyToken.isEmpty
        else { return }
        guard case .missing = OrbitKeychain.read(
            service: Self.keychainService, account: Self.sessionTokenKey
        ) else { return }

        let legacyExpiry = defaults.string(forKey: Self.sessionExpiresAtKey)
        let tokenStatus = OrbitKeychain.write(
            service: Self.keychainService, account: Self.sessionTokenKey, value: legacyToken
        )
        var expiryStatus = errSecSuccess
        if let legacyExpiry, !legacyExpiry.isEmpty {
            expiryStatus = OrbitKeychain.write(
                service: Self.keychainService, account: Self.sessionExpiresAtKey, value: legacyExpiry
            )
        }
        guard tokenStatus == errSecSuccess, expiryStatus == errSecSuccess else {
            OrbitKeychain.delete(service: Self.keychainService, account: Self.sessionTokenKey)
            OrbitKeychain.delete(service: Self.keychainService, account: Self.sessionExpiresAtKey)
            OrbitAuthDebugLog.echo("migration skipped — keychain unavailable, token stays in UserDefaults (R1 fallback)")
            Self.logger.notice(
                "Keychain unavailable; the relay session token stays in UserDefaults (R1 fallback)."
            )
            return
        }
        defaults.removeObject(forKey: Self.sessionTokenKey)
        defaults.removeObject(forKey: Self.sessionExpiresAtKey)
        OrbitAuthDebugLog.echo("migrated the relay session token from UserDefaults into the Keychain")
        Self.logger.notice("Migrated the relay session token from UserDefaults into the Keychain.")
    }

    private func markMigrationAttempted() {
        migrationLock.lock()
        didAttemptMigration = true
        migrationLock.unlock()
    }

    private func loadSecret(key: String) -> String? {
        migrateLegacyDefaultsIfNeeded()
        switch OrbitKeychain.read(service: Self.keychainService, account: key) {
        case .found(let value):
            return value
        case .missing, .failed:
            // `.failed` already logged once inside `OrbitKeychain`.
            return UserDefaults.standard.string(forKey: key)
        }
    }

    /// Clears the relay session from **both** stores. Part of the sign-out contract (R4);
    /// see `UserSessionService.signOut()`.
    func clearSession() {
        OrbitKeychain.delete(service: Self.keychainService, account: Self.sessionTokenKey)
        OrbitKeychain.delete(service: Self.keychainService, account: Self.sessionExpiresAtKey)
        UserDefaults.standard.removeObject(forKey: Self.sessionTokenKey)
        UserDefaults.standard.removeObject(forKey: Self.sessionExpiresAtKey)
    }

    var sessionToken: String? {
        loadSecret(key: Self.sessionTokenKey)
    }

    /// ISO-8601 as the relay wrote it. Kept verbatim so nothing is lost to a parse failure.
    var sessionExpiresAtRaw: String? {
        loadSecret(key: Self.sessionExpiresAtKey)
    }

    var sessionExpiresAt: Date? {
        guard let raw = sessionExpiresAtRaw else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    /// False when there is no session at all, or when the one on disk has already lapsed.
    var hasLiveSession: Bool {
        guard sessionToken != nil else { return false }
        guard let expiry = sessionExpiresAt else { return true }
        return expiry > Date()
    }

    // MARK: - Phase 5 verification seam

    /// In-process proof of the Keychain migration, for the Phase 5 verification.
    ///
    /// The plan's original shell check (`defaults read com.orbit.access …`) was struck as
    /// vacuous: the app is sandboxed, so its container plist is not observable from another
    /// shell session and that command reports "absent" whether or not the migration ran. The
    /// only honest assertion is one made **inside the process**, which is what this is. Read it
    /// with a launch that owns the app's stderr:
    ///
    /// ```
    /// open -n --stderr /tmp/orbit.err --env ORBIT_AUTH_DEBUG_TOKEN_STORE=1 -a "Orbit Access"
    /// ```
    ///
    /// (`OSLog` also gets every line, but do not rely on it — see ``OrbitAuthDebugLog``.)
    ///
    /// Two env vars, both inert when unset — a shipped bundle carries neither, and
    /// `run_orbit_access_app.sh` writes neither into `LSEnvironment`:
    ///
    /// - `ORBIT_AUTH_SEED_LEGACY_TOKEN=<token>` seeds a Phase-4-shaped plaintext token into
    ///   `UserDefaults`, so the next launch has something to migrate.
    /// - `ORBIT_AUTH_DEBUG_TOKEN_STORE=1` logs which store each value came from.
    ///
    /// Never logs a token value — only presence, and a truncated fingerprint so two different
    /// tokens can be told apart across launches.
    func runTokenStoreDiagnosticsIfEnabled() {
        let env = ProcessInfo.processInfo.environment
        if let seed = env["ORBIT_AUTH_SEED_LEGACY_TOKEN"], !seed.isEmpty {
            UserDefaults.standard.set(seed, forKey: Self.sessionTokenKey)
            UserDefaults.standard.set(
                env["ORBIT_AUTH_SEED_LEGACY_EXPIRES_AT"] ?? "2099-01-01T00:00:00+00:00",
                forKey: Self.sessionExpiresAtKey
            )
            migrationLock.lock()
            didAttemptMigration = false
            migrationLock.unlock()
            OrbitAuthDebugLog.echo("seeded a legacy UserDefaults token (dev seam)")
            Self.logger.notice("[token-store] seeded a legacy UserDefaults token (dev seam).")
        }

        guard Self.isEnabled(env["ORBIT_AUTH_DEBUG_TOKEN_STORE"]) else { return }

        // Force the migration, then report where each value actually lives.
        let token = sessionToken
        let keychainToken: String?
        if case .found(let value) = OrbitKeychain.read(
            service: Self.keychainService, account: Self.sessionTokenKey
        ) { keychainToken = value } else { keychainToken = nil }
        let defaultsToken = UserDefaults.standard.string(forKey: Self.sessionTokenKey)
        let defaultsExpiry = UserDefaults.standard.string(forKey: Self.sessionExpiresAtKey)

        OrbitAuthDebugLog.echo(
            """
            token-store: keychain=\(keychainToken.map(Self.fingerprint) ?? "nil") \
            userdefaults=\(defaultsToken.map(Self.fingerprint) ?? "nil") \
            userdefaults_expiry=\(defaultsExpiry == nil ? "nil" : "present") \
            resolved=\(token.map(Self.fingerprint) ?? "nil") \
            expires_at=\(sessionExpiresAtRaw ?? "nil") \
            live=\(hasLiveSession) keychain_fault=\(OrbitKeychain.isFaultInjected)
            """
        )
        Self.logger.notice(
            """
            [token-store] keychain=\(keychainToken.map(Self.fingerprint) ?? "nil", privacy: .public) \
            userdefaults=\(defaultsToken.map(Self.fingerprint) ?? "nil", privacy: .public) \
            userdefaults_expiry=\(defaultsExpiry == nil ? "nil" : "present", privacy: .public) \
            resolved=\(token.map(Self.fingerprint) ?? "nil", privacy: .public) \
            expires_at=\(self.sessionExpiresAtRaw ?? "nil", privacy: .public) \
            live=\(self.hasLiveSession, privacy: .public) \
            keychain_fault=\(OrbitKeychain.isFaultInjected, privacy: .public)
            """
        )
    }

    /// Presence + identity without disclosure: first 4 characters and the length.
    private static func fingerprint(_ token: String) -> String {
        "\(token.prefix(4))…(\(token.count))"
    }

    private static func isEnabled(_ raw: String?) -> Bool {
        guard let raw else { return false }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "1" || value == "true" || value == "yes" || value == "on"
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8)
        }
        if let detail = obj["detail"] as? [String: Any], let error = detail["error"] as? String {
            return error
        }
        if let error = obj["error"] as? String {
            return error
        }
        return nil
    }
}
