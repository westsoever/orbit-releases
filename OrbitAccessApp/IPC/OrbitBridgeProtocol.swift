import Foundation

protocol OrbitBridgeProtocol: Sendable {
    var isDaemonAlive: Bool { get }
    var capturePaused: Bool { get }
    func checkStatus() async -> Bool
    func requestShutdown() async throws
    func fetchPendingTasks() async -> [TaskLogEntry]
    /// All of today's task_log rows, any status. Same open-route conventions as
    /// `fetchPendingTasks()`; feeds the Kanban board (Plan 35), not just `detected`.
    func fetchKanbanTasks() async -> [TaskLogEntry]
    func approve(id: Int64, prompt: String) async throws -> ApproveTaskResponse
    /// `POST /api/tasks` — manual task entry from the Detected column's inline composer
    /// (Plan 42-B). Same auth/error shape as `approve`; returns the new row's id.
    func createTask(title: String, description: String?) async throws -> Int64
    func fetchTaskStatus(id: Int64) async throws -> TaskStatusResponse
    func skip(id: Int64) async throws
    func search(
        _ query: String,
        limit: Int,
        since: String?,
        until: String?,
        appBundleId: String?
    ) async -> [SearchHit]
    /// `model` is an optional per-request override (a local Ollama model tag).
    /// `nil` means "use whatever the daemon is configured with". `appBundleId`,
    /// `since`, and `until` scope retrieval the same way `search(...)` does
    /// (`/api/chat` already accepts them server-side, `server.py:960-967`) and
    /// are omitted from the request body when nil.
    func chatStream(
        _ query: String,
        model: String?,
        appBundleId: String?,
        since: String?,
        until: String?
    ) -> AsyncThrowingStream<ChatChunk, Error>
    func fetchPrivacyStatus() async throws -> PrivacyStatusResponse
    func setCapturePaused(_ paused: Bool) async throws -> PrivacyStatusResponse
    func updateExclusions(add: [String], remove: [String]) async throws -> PrivacyStatusResponse
    func forgetRecent(minutes: Int) async throws -> ForgetResponse
    func exportCaptureData() async throws -> ExportResponse
    func deleteAllCaptureData() async throws
    func fetchSetupStatus() async throws -> SetupStatusResponse
    func fetchCaptureHealth(hours: Int) async throws -> CaptureHealthResponse
    /// `llm: true` makes the daemon spend one `daily_digest` completion and requires
    /// the bridge token; see `InsightStore.refreshDigest` for who is allowed to ask.
    func fetchDigest(day: String?, markdown: Bool, llm: Bool) async throws -> DigestResponse
    func fetchLocalModels() async throws -> LocalModelsResponse
    /// Starts one detection run over Orbit's own captures. Auth'd (it spends a completion
    /// and writes `task_log` rows) and asynchronous: the 202 means "queued", so the caller
    /// polls `fetchDetectStatus()`. Throws `.detectAlreadyRunning` on the daemon's 409.
    func requestDetect(sinceHours: Double, refresh: Bool) async throws -> DetectRunResponse
    /// State of the most recent detection run. Open route — run state only, no captured text.
    func fetchDetectStatus() async throws -> DetectStatusResponse
    /// The most recently closed work session plus files touched during it. Zero
    /// cost: no LLM call, no approval gate — powers the "Resume where you left
    /// off" card (Plan 17 Phase 5.5). Open route, same conventions as `/api/sessions`.
    func fetchLastSession() async throws -> LastSessionResponse
    /// All sessions for a calendar `day` ("today", `nil`, or `yyyy-MM-dd`), oldest-first
    /// within the day. Zero cost like `fetchLastSession()` — no LLM call, no approval
    /// gate, open route. Powers the Timeline view (Plan 17 Phase 6.2).
    func fetchSessions(day: String?, limit: Int) async throws -> SessionsResponse

    // MARK: - Store reads (plan 51 decision D1 — the daemon owns the database)
    //
    // `~/.orbit/orbit.db` is SQLCipher-encrypted and only the Python daemon holds the key,
    // so nothing in this app opens it. Every read below used to be a GRDB query in
    // `IPC/OrbitDBReader.swift`; the routes are specified in `docs/bridge-api-additions.md`.
    //
    // Three conventions apply to all of them:
    //  1. **Authenticated.** Unlike the older GETs above, these require the bridge token
    //     (`docs/bridge-api-additions.md` §0.1) — they serve full captured atom text.
    //  2. **User-scoped daemon-side** from `~/.orbit/session.json` (§0.2). No route takes a
    //     user id; the client cannot select a different user.
    //  3. **Six of them return `/api/search`'s atom payload byte-for-byte** (§0.4), which is
    //     why they decode as `[SearchHit]` and introduce no new atom model.

    /// `GET /api/notes/recent` — atoms with `text_atoms.id > afterId`, newest first,
    /// `length(trim(text)) > 10`. The incremental half of the Context Stream card.
    func fetchRecentNotes(afterId: Int64, limit: Int) async throws -> [SearchHit]

    /// `GET /api/notes/recent/tail` — the same query without the `id >` predicate: the
    /// full-reload half of the Context Stream card.
    func fetchRecentNotesTail(limit: Int) async throws -> [SearchHit]

    /// `GET /api/atoms/today` — atom count for the **UTC** day. Deliberately UTC: this is
    /// the number already shown in the menu bar, and moving it to a local day would move
    /// the count users have been reading (`docs/bridge-api-additions.md` route 3).
    func fetchAtomsCapturedToday() async throws -> Int

    /// `GET /api/score/inputs` — the four 0…1 productivity-score inputs, UTC day. The
    /// 0–10 arithmetic stays in Swift (`productivityScore(_:)`).
    func fetchScoreInputs() async throws -> ScoreInputs

    /// `GET /api/atoms` — atoms in `[since, until]`, **oldest first**. `since`/`until` are
    /// a session's own `started_at`/`ended_at`, compared textually against
    /// `context_events.timestamp`, so they are passed through verbatim.
    func fetchAtomsInRange(since: String, until: String, limit: Int) async throws -> [SearchHit]

    /// `GET /api/usage/snapshot` — the whole Usage Insights sheet in one response
    /// (0.106 s measured against the live 228 MB store). `day` is a local calendar day
    /// (`yyyy-MM-dd` or `"today"`) and scopes only the two "today" counters.
    func fetchUsageSnapshot(
        days: Int,
        breakdownDays: Int,
        appLimit: Int,
        day: String?
    ) async throws -> UsageSnapshot

    /// `GET /api/atoms/by-app` — `app_name LIKE '%appName%'` (display name, not bundle id),
    /// newest first.
    func fetchAtomsByApp(_ appName: String, limit: Int) async throws -> [SearchHit]

    /// `GET /api/atoms/by-hour` — today's atoms (UTC day) for one **UTC** hour, newest
    /// first. `nil` means every hour. Non-digit input is rejected by the daemon with a 400.
    func fetchAtomsByHour(_ hour: String?, limit: Int) async throws -> [SearchHit]

    /// `GET /api/app/latest` — most recently captured bundle id, skipping `excluding`.
    /// `nil` only when nothing has ever been captured.
    func fetchLatestAppBundleId(excluding: [String]) async throws -> String?

    /// `GET /api/user/<id>` — `nil` on the daemon's 404, so "no such user" is a value and
    /// not an error, exactly as the `try? fetchUser` it replaces behaved.
    func fetchUser(id: String) async throws -> OrbitUser?

    /// `POST /api/users` — the database half of sign-up: inserts `users` + `user_sessions`
    /// in one transaction. It deliberately does **not** write `~/.orbit/session.json`, so
    /// the caller must still persist the session file or the daemon keeps the old active
    /// user (`docs/bridge-api-additions.md` route 11).
    func createUser(email: String, displayName: String, cloudUserId: String?) async throws -> OrbitUser

    /// `POST /api/user/link` — writes `cloud_user_id` onto an existing `users` row after a
    /// successful magic-link verify (plan 53 Phase 4). Nothing else about the row changes,
    /// and no row is created: the local identity already exists by the time anyone signs in.
    func linkUserCloudAccount(userId: String, cloudUserId: String) async throws -> OrbitUser
}

/// One row from `get_sessions`/`current_session` (`orbit/memory/sessions.py`), as
/// returned by `GET /api/sessions/last` and `GET /api/sessions`.
struct LastSessionInfo: Decodable, Identifiable, Sendable {
    let id: Int
    let startedAt: String
    let endedAt: String
    let primaryBundleId: String?
    let primaryAppName: String?
    let eventCount: Int
    let atomCount: Int
    let switchCount: Int
    /// Set only once `summarize_session` has run for this session; both nil
    /// until then, since titling/summarization is lazy (Plan 17 Phase 3.3).
    let title: String?
    let summary: String?

    enum CodingKeys: String, CodingKey {
        case id
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case primaryBundleId = "primary_bundle_id"
        case primaryAppName = "primary_app_name"
        case eventCount = "event_count"
        case atomCount = "atom_count"
        case switchCount = "switch_count"
        case title, summary
    }
}

/// `GET /api/sessions/last` → 200. `session` is nil when nothing has been
/// segmented yet (e.g. a fresh install with under `min_events` captured).
struct LastSessionResponse: Decodable, Sendable {
    let session: LastSessionInfo?
    let files: [String]
}

/// `GET /api/sessions` → 200. `day` echoes back whatever the daemon resolved
/// (always a concrete string — `_handle_sessions` defaults an absent query param
/// to `"today"`, it is never null on the wire).
struct SessionsResponse: Decodable, Sendable {
    let day: String
    let sessions: [LastSessionInfo]
}

/// `POST /api/detect` → 202. Matches `_handle_detect`'s payload.
struct DetectRunResponse: Decodable, Sendable {
    let ok: Bool
    let state: String
    let runId: Int

    enum CodingKeys: String, CodingKey {
        case ok, state
        case runId = "run_id"
    }
}

/// `GET /api/detect/status` → 200. Matches `_handle_detect_status`'s payload.
struct DetectStatusResponse: Decodable, Sendable {
    let ok: Bool
    /// idle | running | done | error
    let state: String
    let runId: Int
    let startedAt: String?
    let finishedAt: String?
    let taskCount: Int
    let taskIds: [Int64]
    /// Already user-facing when set: the daemon formats these, Swift only renders them.
    let error: String?
    /// no_captures | no_user | llm | model_output | unknown
    let errorKind: String?

    enum CodingKeys: String, CodingKey {
        case ok, state, error
        case runId = "run_id"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case taskCount = "task_count"
        case taskIds = "task_ids"
        case errorKind = "error_kind"
    }
}

struct DigestResponse: Decodable, Sendable {
    let day: String?
    let markdown: String?
    let narrative: String?
    let source: String?
    let totalEvents: Int?
    let totalAtoms: Int?
    /// `build_digest` returns the session rows themselves rather than a count, so the
    /// card sizes this array instead of reading a `session_count` key that does not exist.
    let sessions: [DigestSession]?

    var sessionCount: Int { sessions?.count ?? 0 }

    enum CodingKeys: String, CodingKey {
        case day, markdown, narrative, source, sessions
        case totalEvents = "total_events"
        case totalAtoms = "total_atoms"
    }
}

/// One row of `build_digest`'s `sessions` list, decoded only as far as the card needs.
struct DigestSession: Decodable, Sendable {
    let primaryAppName: String?

    enum CodingKeys: String, CodingKey {
        case primaryAppName = "primary_app_name"
    }
}

enum OrbitBridgeError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case serverMessage(String)
    case daemonOffline
    /// The daemon's 409 on `POST /api/detect`. Its own case because "a run is already
    /// going" is not a failure, and `.httpStatus(409)` would read as "returned an error".
    case detectAlreadyRunning
    /// A chat stream went quiet for longer than `OrbitBridgeClient.chatStreamInactivityTimeout`
    /// without terminating. Distinct from `.httpStatus(504)`: the daemon answered 200 and
    /// then stopped talking mid-body, which is a framing/transport failure, not a model one.
    /// Raised so a stalled stream surfaces as a visible error instead of a stuck spinner.
    case chatStreamStalled

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "orbit returned an unexpected response. Try restarting the daemon from the sidebar."
        case .httpStatus(let code):
            switch code {
            case 503:
                return "orbit could not answer right now. Check that AI is configured (Cloud AI, an API key in ~/.orbit/.env, or a local Ollama model)."
            case 502, 504:
                return "orbit timed out while generating an answer. Try a shorter question or check your AI provider."
            default:
                return "orbit daemon returned an error (HTTP \(code)). Try restarting the daemon."
            }
        case .serverMessage(let message):
            return ChatErrorFormatter.relayRegistrationMessage(message)
        case .daemonOffline:
            return "orbit's background service is not responding. It starts automatically with the app — quit and reopen orbit if this persists."
        case .detectAlreadyRunning:
            return "orbit is already looking at your context."
        case .chatStreamStalled:
            return "orbit stopped responding part-way through the answer. Try asking again."
        }
    }
}

struct DaemonStatusResponse: Decodable, Sendable {
    let ok: Bool
    let captureActive: Bool?
    let capturePaused: Bool?
    let llmAvailable: Bool?
    let llmProvider: String?
    let localModel: String?
    /// Only sent when the resolved provider is local; nil means "not applicable".
    let localModelReady: Bool?
    let localModelHint: String?
    /// Build provenance (plan 34 phase 2). Optional so a daemon older than that
    /// phase still decodes — a decode failure here would read as "daemon offline".
    let version: String?
    let startedAt: String?
    /// Directory of the daemon's loaded `orbit` package: repo tree vs. bundle copy.
    let packagePath: String?
    /// `sys.executable`. Same `orbit` sources under a different interpreter still means
    /// different pyobjc / sqlite-vec builds, so the path alone is not enough.
    let interpreter: String?
    /// nil only when the daemon can identify neither a repo nor a recorded build SHA.
    /// Not a divergence on its own.
    let gitSha: String?
    /// Uncommitted edits in the daemon's tree — when true, equal SHAs prove nothing.
    /// nil where there is no tree to inspect (release bundle).
    let gitDirty: Bool?

    enum CodingKeys: String, CodingKey {
        case ok
        case captureActive = "capture_active"
        case capturePaused = "capture_paused"
        case llmAvailable = "llm_available"
        case llmProvider = "llm_provider"
        case localModel = "local_model"
        case localModelReady = "local_model_ready"
        case localModelHint = "local_model_hint"
        case version
        case startedAt = "started_at"
        case packagePath = "package_path"
        case interpreter
        case gitSha = "git_sha"
        case gitDirty = "git_dirty"
    }
}

/// The daemon's self-reported build identity, lifted out of the bridge client so
/// `AppViewModel` can hold it as observable state (`OrbitBridgeClient` is a plain class,
/// so views cannot observe its properties directly).
struct DaemonBuildInfo: Equatable, Sendable {
    let version: String?
    let startedAt: String?
    let packagePath: String?
    let interpreter: String?
    let gitSha: String?
    let gitDirty: Bool?
}

struct LocalModelsResponse: Decodable, Sendable {
    let ok: Bool
    let provider: String?
    let models: [String]
    let current: String?

    enum CodingKeys: String, CodingKey {
        case ok, provider, models, current
    }
}

struct PrivacyStatusResponse: Decodable, Sendable {
    let ok: Bool
    let capturePaused: Bool
    let excludedBundles: [String]
    let builtinExclusions: [String]
    let retentionDays: Int

    enum CodingKeys: String, CodingKey {
        case ok
        case capturePaused = "capture_paused"
        case excludedBundles = "excluded_bundles"
        case builtinExclusions = "builtin_exclusions"
        case retentionDays = "retention_days"
    }
}

struct ForgetResponse: Decodable, Sendable {
    let ok: Bool
    let deletedEvents: Int
    let minutes: Int

    enum CodingKeys: String, CodingKey {
        case ok
        case deletedEvents = "deleted_events"
        case minutes
    }
}

struct ExportResponse: Decodable, Sendable {
    let ok: Bool
    let events: Int
    let path: String
}

struct SetupChecklistItem: Decodable, Identifiable, Sendable {
    let id: String
    let label: String
    let ok: Bool
    let detail: String?
}

struct SetupLLMStatus: Decodable, Sendable {
    let path: String
    let cloud: Bool
    let byok: Bool
    let local: Bool
    let ready: Bool
    /// Only sent when the resolved provider is local; nil means "not applicable".
    let localModelReady: Bool?
    let localModelHint: String?

    enum CodingKeys: String, CodingKey {
        case path, cloud, byok, local, ready
        case localModelReady = "local_model_ready"
        case localModelHint = "local_model_hint"
    }
}

struct SetupStatusResponse: Decodable, Sendable {
    let ok: Bool
    let accessibilityTrusted: Bool?
    let daemonRunning: Bool
    let captureActive: Bool
    let capturePaused: Bool
    let llm: SetupLLMStatus
    let checklist: [SetupChecklistItem]

    enum CodingKeys: String, CodingKey {
        case ok
        case accessibilityTrusted = "accessibility_trusted"
        case daemonRunning = "daemon_running"
        case captureActive = "capture_active"
        case capturePaused = "capture_paused"
        case llm
        case checklist
    }
}

struct CaptureHealthApp: Decodable, Identifiable, Sendable {
    var id: String { bundleId }
    let bundleId: String
    let appName: String
    let eventCount: Int
    let goodCount: Int
    let emptyCount: Int
    let status: String
    let excluded: Bool

    enum CodingKeys: String, CodingKey {
        case bundleId = "bundle_id"
        case appName = "app_name"
        case eventCount = "event_count"
        case goodCount = "good_count"
        case emptyCount = "empty_count"
        case status
        case excluded
    }
}

struct CaptureHealthResponse: Decodable, Sendable {
    let ok: Bool
    let hours: Int
    let capturePaused: Bool
    let apps: [CaptureHealthApp]

    enum CodingKeys: String, CodingKey {
        case ok
        case hours
        case capturePaused = "capture_paused"
        case apps
    }
}

extension OrbitBridgeProtocol {
    func search(_ query: String, limit: Int = 20) async -> [SearchHit] {
        await search(query, limit: limit, since: nil, until: nil, appBundleId: nil)
    }

    func chatStream(_ query: String) -> AsyncThrowingStream<ChatChunk, Error> {
        chatStream(query, model: nil, appBundleId: nil, since: nil, until: nil)
    }

    func chatStream(_ query: String, model: String?) -> AsyncThrowingStream<ChatChunk, Error> {
        chatStream(query, model: model, appBundleId: nil, since: nil, until: nil)
    }

    /// Zero-cost digest: the structured summary, no completion, no token needed.
    func fetchDigest(day: String? = "today", markdown: Bool = true) async throws -> DigestResponse {
        try await fetchDigest(day: day, markdown: markdown, llm: false)
    }

    /// Defaults match the daemon's own (`day="today"`, `limit=50`) — see `_handle_sessions`.
    func fetchSessions(day: String? = "today", limit: Int = 50) async throws -> SessionsResponse {
        try await fetchSessions(day: day, limit: limit)
    }

    // Default arguments for the store reads, matching the defaults the deleted
    // `OrbitDBReader` methods had. These forward to the protocol requirement, so the
    // conforming client's implementation still runs (dynamic dispatch through the
    // witness table) — the same pattern `fetchSessions` above uses.

    func fetchRecentNotes(afterId: Int64, limit: Int = 10) async throws -> [SearchHit] {
        try await fetchRecentNotes(afterId: afterId, limit: limit)
    }

    func fetchRecentNotesTail(limit: Int = 10) async throws -> [SearchHit] {
        try await fetchRecentNotesTail(limit: limit)
    }

    func fetchAtomsInRange(since: String, until: String, limit: Int = 100) async throws -> [SearchHit] {
        try await fetchAtomsInRange(since: since, until: until, limit: limit)
    }

    /// `days` sizes the streak grid, `breakdownDays` the app/tier/task/model breakdowns.
    func fetchUsageSnapshot(
        days: Int = 182,
        breakdownDays: Int = 30,
        appLimit: Int = 8,
        day: String? = "today"
    ) async throws -> UsageSnapshot {
        try await fetchUsageSnapshot(days: days, breakdownDays: breakdownDays, appLimit: appLimit, day: day)
    }

    func fetchAtomsByApp(_ appName: String, limit: Int = 20) async throws -> [SearchHit] {
        try await fetchAtomsByApp(appName, limit: limit)
    }

    func fetchAtomsByHour(_ hour: String?, limit: Int = 20) async throws -> [SearchHit] {
        try await fetchAtomsByHour(hour, limit: limit)
    }

    func fetchLatestAppBundleId(excluding: [String] = []) async throws -> String? {
        try await fetchLatestAppBundleId(excluding: excluding)
    }
}

/// `GET /api/atoms/today` → `{"count": <int>}`. Never partial: an empty store returns 0.
struct AtomCountResponse: Decodable, Sendable {
    let count: Int
}

/// `GET /api/app/latest` → `{"app_bundle_id": <string|null>}`; null on an empty store.
struct LatestAppResponse: Decodable, Sendable {
    let appBundleId: String?

    enum CodingKeys: String, CodingKey {
        case appBundleId = "app_bundle_id"
    }
}

/// `POST /api/users` → 200 `{"ok": true, "user": {…}}`. The nested object's keys are
/// `OrbitUser`'s own `CodingKeys`, so it decodes unchanged.
struct CreateUserResponse: Decodable, Sendable {
    let ok: Bool
    let user: OrbitUser
}

struct SearchResponse: Decodable, Sendable {
    let hits: [SearchHit]
}

struct PendingTasksResponse: Decodable, Sendable {
    let tasks: [TaskLogEntry]

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let array = try? container.decode([TaskLogEntry].self) {
            tasks = array
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try container.decodeIfPresent([TaskLogEntry].self, forKey: .tasks) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case tasks
    }
}

/// `GET /api/tasks/kanban` → all of today's rows, any status. Same decoding
/// shape as `PendingTasksResponse` (raw array or `{"tasks": [...]}`).
struct KanbanTasksResponse: Decodable, Sendable {
    let tasks: [TaskLogEntry]

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let array = try? container.decode([TaskLogEntry].self) {
            tasks = array
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try container.decodeIfPresent([TaskLogEntry].self, forKey: .tasks) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case tasks
    }
}

struct ApproveTaskBody: Encodable {
    let approvedPrompt: String

    enum CodingKeys: String, CodingKey {
        case approvedPrompt = "approved_prompt"
    }
}

struct ApproveTaskResponse: Decodable, Sendable {
    let ok: Bool
    let id: Int64
    let status: String
}

/// `POST /api/tasks` body — program §4.1. `description` is optional, same as the route.
struct CreateTaskBody: Encodable {
    let title: String
    let description: String?
}

/// `POST /api/tasks` → 200 `{"ok": true, "id": <int>}` (program §4.1).
struct CreateTaskResponse: Decodable, Sendable {
    let ok: Bool
    let id: Int64
}

struct TaskStatusResponse: Decodable, Sendable {
    let ok: Bool
    let id: Int64
    let title: String?
    let status: String
    let exitCode: Int?
    let resultPath: String?
    let resultPreview: String?

    enum CodingKeys: String, CodingKey {
        case ok, id, title, status
        case exitCode = "exit_code"
        case resultPath = "result_path"
        case resultPreview = "result_preview"
    }
}
