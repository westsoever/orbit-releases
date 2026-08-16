import Foundation

/// Plan 53 Phase 6 — the data half of the profile questionnaire.
///
/// The answers describe the *person*, not their captured context: degree, position, function,
/// area, plus free text. That makes them non-essential profiling under GDPR, so everything
/// here is built around one rule — **nothing is sent without a separate, explicit consent**,
/// and that consent is recorded with the moment it was given and the privacy-policy version it
/// was given against. See `docs/gdpr/PRIVACY_POLICY.md` § "Account and profile data".
///
/// The answers are meaningless without a cloud account (they sync to the relay and nowhere
/// else), so `ProfileRelayClient` refuses to run when the feature flag is off or there is no
/// relay session, and the UI is not offered in those states either.

// MARK: - Answers

/// One person's answers. Every field is optional — no question is mandatory.
struct ProfileAnswers: Equatable {
    var degree: String?
    var position: String?
    var function: String?
    var area: String?
    var other: String = ""

    var isEmpty: Bool {
        degree == nil && position == nil && function == nil && area == nil
            && other.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Question catalogue

enum ProfileQuestionnaire {
    /// The privacy-policy version the consent checkbox is worded against. Bump this **only**
    /// together with the "Account and profile data" section of `docs/gdpr/PRIVACY_POLICY.md`;
    /// the relay stores it verbatim so a later policy change can be told apart from consent
    /// given under the current text.
    static let policyVersion = "2026-08-16"

    static let degreeOptions = [
        "High school",
        "Vocational",
        "Bachelor's",
        "Master's",
        "PhD",
        "Self-taught",
    ]

    static let positionOptions = [
        "Student",
        "Individual contributor",
        "Team lead",
        "Manager",
        "Director / VP",
        "Founder / owner",
        "Freelance / consultant",
    ]

    static let functionOptions = [
        "Engineering",
        "Design",
        "Product",
        "Research",
        "Data / analytics",
        "Marketing",
        "Sales",
        "Operations",
        "Finance",
        "Legal",
        "People / HR",
        "Support",
    ]

    static let areaOptions = [
        "Software / tech",
        "Finance",
        "Healthcare",
        "Education",
        "Public sector",
        "Media / creative",
        "Manufacturing",
        "Retail / e-commerce",
        "Nonprofit",
        "Consulting",
    ]
}

// MARK: - Local copy

/// Keeps the last submitted answers on this Mac so re-opening the questionnaire shows what was
/// sent rather than a blank form ("resumable", Phase 6 task 4).
///
/// Written **only** after a consented submission succeeds, and erased on withdrawal — so a
/// skipped questionnaire leaves nothing behind locally either. Raw-string `UserDefaults` keys,
/// following the convention in `OrbitAccessApp.swift` (no key constants).
enum ProfileAnswersStore {
    private static let defaults = UserDefaults.standard

    static func load() -> ProfileAnswers? {
        guard defaults.string(forKey: "orbit.profile.consent_at") != nil else { return nil }
        return ProfileAnswers(
            degree: defaults.string(forKey: "orbit.profile.degree"),
            position: defaults.string(forKey: "orbit.profile.position"),
            function: defaults.string(forKey: "orbit.profile.function"),
            area: defaults.string(forKey: "orbit.profile.area"),
            other: defaults.string(forKey: "orbit.profile.other") ?? ""
        )
    }

    static var hasSubmitted: Bool {
        defaults.string(forKey: "orbit.profile.consent_at") != nil
    }

    static func save(_ answers: ProfileAnswers, policyVersion: String, consentAt: Date) {
        set(answers.degree, "orbit.profile.degree")
        set(answers.position, "orbit.profile.position")
        set(answers.function, "orbit.profile.function")
        set(answers.area, "orbit.profile.area")
        set(answers.other.isEmpty ? nil : answers.other, "orbit.profile.other")
        defaults.set(policyVersion, forKey: "orbit.profile.policy_version")
        defaults.set(ISO8601DateFormatter().string(from: consentAt), forKey: "orbit.profile.consent_at")
    }

    static func clear() {
        for key in [
            "orbit.profile.degree",
            "orbit.profile.position",
            "orbit.profile.function",
            "orbit.profile.area",
            "orbit.profile.other",
            "orbit.profile.policy_version",
            "orbit.profile.consent_at",
        ] {
            defaults.removeObject(forKey: key)
        }
    }

    private static func set(_ value: String?, _ key: String) {
        if let value, !value.isEmpty {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

// MARK: - Relay client

enum ProfileSyncError: LocalizedError {
    case cloudAuthDisabled
    case notSignedIn
    case relay(String)

    var errorDescription: String? {
        switch self {
        case .cloudAuthDisabled:
            return "Cloud accounts are not enabled in this build."
        case .notSignedIn:
            return "Sign in first — these answers are stored with your orbit account."
        case .relay(let message):
            return message
        }
    }
}

/// `POST /v1/profile` and `DELETE /v1/profile`, bearer-authenticated with the relay session
/// token minted by `UserAuthService.verifyMagicLink`.
///
/// Shaped exactly like `UserAuthService`'s request methods (same `URLRequest` construction,
/// same 15s timeout, same `{"detail":{"error":…}}` unwrap) — it lives beside the only view
/// that calls it rather than in `Services/`, and would move there the moment a second caller
/// appears.
final class ProfileRelayClient: @unchecked Sendable {
    static let shared = ProfileRelayClient()

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    private struct ProfileBody: Encodable {
        let degree: String?
        let position: String?
        let function: String?
        let area: String?
        let other: String?
        let consent: Bool
        let policyVersion: String

        enum CodingKeys: String, CodingKey {
            case degree, position, function, area, other, consent
            case policyVersion = "policy_version"
        }
    }

    /// Send the answers. `consent` is passed through rather than assumed: the relay rejects a
    /// body without it, which is the server-side half of "unticked means nothing is stored".
    /// Callers must not reach this method at all with the box unticked.
    func submit(_ answers: ProfileAnswers, consent: Bool, policyVersion: String) async throws {
        let body = ProfileBody(
            degree: answers.degree,
            position: answers.position,
            function: answers.function,
            area: answers.area,
            other: answers.other.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : answers.other.trimmingCharacters(in: .whitespacesAndNewlines),
            consent: consent,
            policyVersion: policyVersion
        )
        var request = try authorizedRequest(method: "POST")
        request.httpBody = try JSONEncoder().encode(body)
        try await send(request)
    }

    /// Withdraw consent and erase the stored answers on the relay.
    func withdraw() async throws {
        try await send(authorizedRequest(method: "DELETE"))
    }

    private func authorizedRequest(method: String) throws -> URLRequest {
        guard UserAuthService.isCloudAuthEnabled else { throw ProfileSyncError.cloudAuthDisabled }
        guard let token = UserAuthService.shared.sessionToken else {
            throw ProfileSyncError.notSignedIn
        }
        var request = URLRequest(
            url: CloudAIService.defaultRelayURL.appendingPathComponent("/v1/profile")
        )
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        return request
    }

    private func send(_ request: URLRequest) async throws {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProfileSyncError.relay("Invalid response from relay.")
        }
        guard http.statusCode == 200 else {
            throw ProfileSyncError.relay(
                Self.errorMessage(from: data) ?? "HTTP \(http.statusCode)"
            )
        }
    }

    /// Same unwrap as `UserAuthService.errorMessage(from:)`: the relay's convention is
    /// `{"detail": {"error": "snake_case"}}`, with a bare `{"error": …}` as the fallback.
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
