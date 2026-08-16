import Foundation
import os

/// `@unchecked Sendable` is truthful here, and only because of `state` below: every
/// mutable field this class owns lives inside one `DaemonState` value guarded by an
/// `OSAllocatedUnfairLock`, and there is no other path to it. (`base` and `session` are
/// immutable `let`s; `URLSession` is itself thread-safe.)
///
/// It did not used to be truthful. These nine fields were nine independent
/// `private(set) var`s, and `checkStatus()` wrote all nine on whatever cooperative
/// thread it happened to land on. Because nearly every method here opens with
/// `guard await checkStatus()`, and `AppViewModel`/`TaskStore`/`InsightStore`/
/// `UsageInsightsStore` all poll on their own timers, those writes overlapped
/// routinely. Two threads storing into `daemonBuild` — an optional struct of
/// refcounted `String`s — released the same storage twice and the app took a
/// `SIGSEGV` in `_swift_release_dealloc` under `outlined destroy of DaemonBuildInfo?`
/// (five crash reports, 2026-08-14). Suppressing the concurrency checker did not make
/// the data race legal; the lock does.
final class OrbitBridgeClient: OrbitBridgeProtocol, @unchecked Sendable {
    /// Everything one `/api/status` response teaches us, as a single value. Readers take
    /// whatever the latest complete poll produced; they can never observe a poll
    /// half-applied, because `checkStatus()` swaps the whole struct in one critical
    /// section rather than assigning field by field.
    private struct DaemonState: Sendable {
        var isDaemonAlive = false
        var captureActive = false
        var capturePaused = false
        var llmAvailable: Bool?
        var llmProvider: String?
        var localModel: String?
        var localModelReady: Bool?
        var localModelHint: String?
        /// nil until the first successful poll, and again whenever the daemon goes away.
        var daemonBuild: DaemonBuildInfo?
    }

    private let base = URL(string: "http://127.0.0.1:8765")!
    private let session: URLSession
    /// macOS 13+; the app targets macOS 14 (`Package.swift:6`, `Info.bundle.plist`
    /// `LSMinimumSystemVersion` 14.0), so no availability guard is needed.
    private let state = OSAllocatedUnfairLock(initialState: DaemonState())

    // Read accessors keep the exact names and types the stored properties had, so no
    // call site changes. Each is one uncontended atomic acquire; nothing here ever
    // awaits while holding the lock.
    var isDaemonAlive: Bool { state.withLock { $0.isDaemonAlive } }
    var captureActive: Bool { state.withLock { $0.captureActive } }
    var capturePaused: Bool { state.withLock { $0.capturePaused } }
    var llmAvailable: Bool? { state.withLock { $0.llmAvailable } }
    var llmProvider: String? { state.withLock { $0.llmProvider } }
    var localModel: String? { state.withLock { $0.localModel } }
    var localModelReady: Bool? { state.withLock { $0.localModelReady } }
    var localModelHint: String? { state.withLock { $0.localModelHint } }
    var daemonBuild: DaemonBuildInfo? { state.withLock { $0.daemonBuild } }

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    func checkStatus() async -> Bool {
        do {
            let request = URLRequest(url: base.appendingPathComponent("/api/status"))
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                // Unchanged semantics: a non-200 marks the daemon dead and leaves every
                // other field exactly as the previous poll left it.
                state.withLock { $0.isDaemonAlive = false }
                return false
            }
            let status = try JSONDecoder().decode(DaemonStatusResponse.self, from: data)
            let next = DaemonState(
                isDaemonAlive: status.ok,
                captureActive: status.captureActive ?? false,
                capturePaused: status.capturePaused ?? false,
                llmAvailable: status.llmAvailable,
                llmProvider: status.llmProvider,
                localModel: status.localModel,
                localModelReady: status.localModelReady,
                localModelHint: status.localModelHint,
                daemonBuild: DaemonBuildInfo(
                    version: status.version,
                    startedAt: status.startedAt,
                    packagePath: status.packagePath,
                    interpreter: status.interpreter,
                    gitSha: status.gitSha,
                    gitDirty: status.gitDirty
                )
            )
            state.withLock { $0 = next }
            return status.ok
        } catch {
            // Same reset-to-nil/false semantics as before, applied as one swap.
            state.withLock { $0 = DaemonState() }
            return false
        }
    }

    func requestShutdown() async throws {
        var request = URLRequest(url: base.appendingPathComponent("/api/shutdown"))
        request.httpMethod = "POST"
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 204 else {
            throw OrbitBridgeError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        state.withLock {
            $0.isDaemonAlive = false
            $0.captureActive = false
        }
    }

    func fetchPrivacyStatus() async throws -> PrivacyStatusResponse {
        try await getJSON("/api/privacy/status")
    }

    func setCapturePaused(_ paused: Bool) async throws -> PrivacyStatusResponse {
        let path = paused ? "/api/privacy/pause" : "/api/privacy/resume"
        let response: PrivacyStatusResponse = try await postJSON(path, body: Optional<String>.none, auth: true)
        state.withLock { $0.capturePaused = response.capturePaused }
        return response
    }

    func updateExclusions(add: [String], remove: [String]) async throws -> PrivacyStatusResponse {
        struct Body: Encodable {
            let add: [String]
            let remove: [String]
        }
        return try await postJSON("/api/privacy/exclusions", body: Body(add: add, remove: remove), auth: true)
    }

    func forgetRecent(minutes: Int) async throws -> ForgetResponse {
        struct Body: Encodable { let minutes: Int }
        return try await postJSON("/api/privacy/forget", body: Body(minutes: minutes), auth: true)
    }

    func exportCaptureData() async throws -> ExportResponse {
        try await postJSON("/api/privacy/export", body: [String: String](), auth: true)
    }

    func deleteAllCaptureData() async throws {
        struct Body: Encodable { let confirm: Bool }
        struct DeleteResponse: Decodable { let ok: Bool }
        let _: DeleteResponse = try await postJSON(
            "/api/privacy/delete",
            body: Body(confirm: true),
            auth: true
        )
    }

    func fetchSetupStatus() async throws -> SetupStatusResponse {
        try await getJSON("/api/setup/status")
    }

    func fetchCaptureHealth(hours: Int = 24) async throws -> CaptureHealthResponse {
        guard await checkStatus() else { throw OrbitBridgeError.daemonOffline }
        var components = URLComponents(
            url: base.appendingPathComponent("/api/capture/health"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "hours", value: String(hours))]
        guard let url = components.url else { throw OrbitBridgeError.invalidResponse }
        let (data, response) = try await session.data(for: URLRequest(url: url))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OrbitBridgeError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(CaptureHealthResponse.self, from: data)
    }

    func fetchDigest(day: String?, markdown: Bool, llm: Bool) async throws -> DigestResponse {
        guard await checkStatus() else { throw OrbitBridgeError.daemonOffline }
        var components = URLComponents(
            url: base.appendingPathComponent("/api/digest"),
            resolvingAgainstBaseURL: false
        )!
        var items: [URLQueryItem] = []
        if let day, !day.isEmpty {
            items.append(URLQueryItem(name: "day", value: day))
        }
        if markdown {
            items.append(URLQueryItem(name: "markdown", value: "1"))
        }
        if llm {
            items.append(URLQueryItem(name: "llm", value: "1"))
        }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else { throw OrbitBridgeError.invalidResponse }
        var request = URLRequest(url: url)
        // Only the llm=1 form is authenticated; sending the token unconditionally would
        // widen the plain digest's contract for no gain.
        if llm, let token = OrbitPaths.loadBridgeToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            // Outlast the daemon's own completion budget (ORBIT_LLM_TIMEOUT_S,
            // default 90s). URLSession's 60s default would give up while the
            // daemon finishes and bills the completion anyway — the client would
            // show an error for work that succeeded, and a retry would pay twice.
            request.timeoutInterval = 150
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OrbitBridgeError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(DigestResponse.self, from: data)
    }

    func fetchLocalModels() async throws -> LocalModelsResponse {
        try await getJSON("/api/llm/models")
    }

    func requestDetect(sinceHours: Double, refresh: Bool) async throws -> DetectRunResponse {
        struct Body: Encodable {
            let sinceHours: Double
            let refresh: Bool

            enum CodingKeys: String, CodingKey {
                case sinceHours = "since_hours"
                case refresh
            }
        }
        guard await checkStatus() else { throw OrbitBridgeError.daemonOffline }
        var request = URLRequest(url: base.appendingPathComponent("/api/detect"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = OrbitPaths.loadBridgeToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(Body(sinceHours: sinceHours, refresh: refresh))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OrbitBridgeError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            // The daemon returns 409 while a run is in flight. That is a state, not a
            // fault, so it gets its own case instead of the generic error extraction.
            if http.statusCode == 409 {
                throw OrbitBridgeError.detectAlreadyRunning
            }
            throw Self.bridgeError(from: data, statusCode: http.statusCode)
        }
        return try JSONDecoder().decode(DetectRunResponse.self, from: data)
    }

    func fetchDetectStatus() async throws -> DetectStatusResponse {
        try await getJSON("/api/detect/status")
    }

    func fetchLastSession() async throws -> LastSessionResponse {
        try await getJSON("/api/sessions/last")
    }

    func fetchSessions(day: String?, limit: Int) async throws -> SessionsResponse {
        guard await checkStatus() else { throw OrbitBridgeError.daemonOffline }
        var components = URLComponents(
            url: base.appendingPathComponent("/api/sessions"),
            resolvingAgainstBaseURL: false
        )!
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let day, !day.isEmpty {
            items.append(URLQueryItem(name: "day", value: day))
        }
        components.queryItems = items
        guard let url = components.url else { throw OrbitBridgeError.invalidResponse }
        let (data, response) = try await session.data(for: URLRequest(url: url))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OrbitBridgeError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(SessionsResponse.self, from: data)
    }

    // MARK: - Store reads (plan 51 decision D1)
    //
    // Query-parameter + typed-decode shape copied from `fetchSessions` above; auth comes
    // from `getJSON`/`authorizedGET`. Nothing here touches `state`, so nothing here can
    // interact with the `DaemonState` lock beyond `checkStatus()`'s own single swap.

    func fetchRecentNotes(afterId: Int64, limit: Int) async throws -> [SearchHit] {
        try await getJSON(
            "/api/notes/recent",
            query: [
                URLQueryItem(name: "after_id", value: String(afterId)),
                URLQueryItem(name: "limit", value: String(limit)),
            ]
        )
    }

    func fetchRecentNotesTail(limit: Int) async throws -> [SearchHit] {
        try await getJSON(
            "/api/notes/recent/tail",
            query: [URLQueryItem(name: "limit", value: String(limit))]
        )
    }

    func fetchAtomsCapturedToday() async throws -> Int {
        let response: AtomCountResponse = try await getJSON("/api/atoms/today")
        return response.count
    }

    func fetchScoreInputs() async throws -> ScoreInputs {
        try await getJSON("/api/score/inputs")
    }

    func fetchAtomsInRange(since: String, until: String, limit: Int) async throws -> [SearchHit] {
        try await getJSON(
            "/api/atoms",
            query: [
                URLQueryItem(name: "since", value: since),
                URLQueryItem(name: "until", value: until),
                URLQueryItem(name: "limit", value: String(limit)),
            ]
        )
    }

    func fetchUsageSnapshot(
        days: Int,
        breakdownDays: Int,
        appLimit: Int,
        day: String?
    ) async throws -> UsageSnapshot {
        var query = [
            URLQueryItem(name: "days", value: String(days)),
            URLQueryItem(name: "breakdown_days", value: String(breakdownDays)),
            URLQueryItem(name: "app_limit", value: String(appLimit)),
        ]
        if let day, !day.isEmpty {
            query.append(URLQueryItem(name: "day", value: day))
        }
        return try await getJSON("/api/usage/snapshot", query: query)
    }

    func fetchAtomsByApp(_ appName: String, limit: Int) async throws -> [SearchHit] {
        try await getJSON(
            "/api/atoms/by-app",
            query: [
                URLQueryItem(name: "app_name", value: appName),
                URLQueryItem(name: "limit", value: String(limit)),
            ]
        )
    }

    func fetchAtomsByHour(_ hour: String?, limit: Int) async throws -> [SearchHit] {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        // Omitted, not blank: the route reads an absent `hour` as "every hour", while a
        // blank one is a 400.
        if let hour, !hour.isEmpty {
            query.append(URLQueryItem(name: "hour", value: hour))
        }
        return try await getJSON("/api/atoms/by-hour", query: query)
    }

    func fetchLatestAppBundleId(excluding: [String]) async throws -> String? {
        let query = excluding
            .filter { !$0.isEmpty }
            .map { URLQueryItem(name: "exclude", value: $0) }
        let response: LatestAppResponse = try await getJSON("/api/app/latest", query: query)
        return response.appBundleId
    }

    /// 404 is mapped to `nil` rather than thrown: "there is no such user" is the same
    /// value the `try? fetchUser(id:)` this replaces produced, and the callers treat a
    /// missing user as "not signed in", not as a failure.
    func fetchUser(id: String) async throws -> OrbitUser? {
        guard await checkStatus() else { throw OrbitBridgeError.daemonOffline }
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let request = try authorizedGET("/api/user/\(encoded)")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OrbitBridgeError.invalidResponse
        }
        if http.statusCode == 404 {
            return nil
        }
        guard http.statusCode == 200 else {
            throw Self.bridgeError(from: data, statusCode: http.statusCode)
        }
        return try JSONDecoder().decode(OrbitUser.self, from: data)
    }

    func createUser(email: String, displayName: String, cloudUserId: String?) async throws -> OrbitUser {
        struct Body: Encodable {
            let email: String
            let displayName: String
            let cloudUserId: String?

            enum CodingKeys: String, CodingKey {
                case email
                case displayName = "display_name"
                case cloudUserId = "cloud_user_id"
            }
        }
        // `postJSON` maps the daemon's 400/409/500 JSON `{"error": …}` bodies to
        // `.serverMessage`, and those strings are already `UserSessionError`'s own
        // user-facing wording, so the sign-up sheet can render them verbatim. A malformed
        // request would come back as HTML instead, which falls through to `.httpStatus`.
        let response: CreateUserResponse = try await postJSON(
            "/api/users",
            body: Body(email: email, displayName: displayName, cloudUserId: cloudUserId),
            auth: true
        )
        return response.user
    }

    /// Plan 53 Phase 4 — the local half of sign-in. Same `postJSON` + nested snake_case
    /// `Body` shape as `createUser` above; the daemon's 404 ("user not found") and 400s come
    /// back as `.serverMessage`. No state is cached from the result: everything mutable this
    /// client owns lives inside `DaemonState` behind the lock, and a linked cloud id is not
    /// daemon status.
    func linkUserCloudAccount(userId: String, cloudUserId: String) async throws -> OrbitUser {
        struct Body: Encodable {
            let userId: String
            let cloudUserId: String

            enum CodingKeys: String, CodingKey {
                case userId = "user_id"
                case cloudUserId = "cloud_user_id"
            }
        }
        let response: CreateUserResponse = try await postJSON(
            "/api/user/link",
            body: Body(userId: userId, cloudUserId: cloudUserId),
            auth: true
        )
        return response.user
    }

    func fetchPendingTasks() async -> [TaskLogEntry] {
        guard await checkStatus() else { return [] }
        do {
            let request = URLRequest(url: base.appendingPathComponent("/api/tasks/pending"))
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            let decoded = try JSONDecoder().decode(PendingTasksResponse.self, from: data)
            return decoded.tasks
        } catch {
            return []
        }
    }

    func fetchKanbanTasks() async -> [TaskLogEntry] {
        guard await checkStatus() else { return [] }
        do {
            let request = URLRequest(url: base.appendingPathComponent("/api/tasks/kanban"))
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            let decoded = try JSONDecoder().decode(KanbanTasksResponse.self, from: data)
            return decoded.tasks
        } catch {
            return []
        }
    }

    func approve(id: Int64, prompt: String) async throws -> ApproveTaskResponse {
        try await postTaskAction(
            id: id,
            pathSuffix: "approve",
            body: ApproveTaskBody(approvedPrompt: prompt),
            as: ApproveTaskResponse.self
        )
    }

    /// Copies `approve`'s request/decode shape verbatim: same Bearer-token header
    /// (`postJSON`'s `auth: true`), same error mapping (`bridgeError(from:statusCode:)`).
    func createTask(title: String, description: String?) async throws -> Int64 {
        let response: CreateTaskResponse = try await postJSON(
            "/api/tasks",
            body: CreateTaskBody(title: title, description: description),
            auth: true
        )
        return response.id
    }

    func fetchTaskStatus(id: Int64) async throws -> TaskStatusResponse {
        guard await checkStatus() else { throw OrbitBridgeError.daemonOffline }
        var request = URLRequest(url: base.appendingPathComponent("/api/task/\(id)"))
        request.httpMethod = "GET"
        if let token = OrbitPaths.loadBridgeToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OrbitBridgeError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = json["error"] as? String,
               !message.isEmpty {
                throw OrbitBridgeError.serverMessage(message)
            }
            throw OrbitBridgeError.httpStatus(http.statusCode)
        }
        return try JSONDecoder().decode(TaskStatusResponse.self, from: data)
    }

    func skip(id: Int64) async throws {
        struct SkipResponse: Decodable { let ok: Bool? }
        let _: SkipResponse = try await postTaskAction(
            id: id,
            pathSuffix: "skip",
            body: Optional<String>.none,
            as: SkipResponse.self
        )
    }

    func search(
        _ query: String,
        limit: Int = 20,
        since: String? = nil,
        until: String? = nil,
        appBundleId: String? = nil
    ) async -> [SearchHit] {
        guard await checkStatus() else { return [] }
        var components = URLComponents(url: base.appendingPathComponent("/api/search"), resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let since, !since.isEmpty {
            items.append(URLQueryItem(name: "since", value: since))
        }
        if let until, !until.isEmpty {
            items.append(URLQueryItem(name: "until", value: until))
        }
        if let appBundleId, !appBundleId.isEmpty {
            items.append(URLQueryItem(name: "app_bundle_id", value: appBundleId))
        }
        components.queryItems = items
        guard let url = components.url else { return [] }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            if let hits = try? JSONDecoder().decode([SearchHit].self, from: data) {
                return hits
            }
            let wrapped = try JSONDecoder().decode(SearchResponse.self, from: data)
            return wrapped.hits
        } catch {
            return []
        }
    }

    /// How long one chat request may go without producing a byte before we give up on it.
    ///
    /// Mirrors the daemon's own per-completion ceiling — `_llm_timeout_s()` in
    /// `orbit/check/llm.py:160-174` (`ORBIT_LLM_TIMEOUT_S`, default 90 s) — plus the same
    /// 60 s of headroom `fetchDigest` already allows above it (`:191-195`), so the client
    /// only ever gives up *after* the daemon has bounded the completion itself and failed
    /// the request properly. That ordering matters: timing out first would report an error
    /// for work that then succeeds and bills anyway. The Python value is not reachable from
    /// Swift, so this is a deliberate mirror — if `ORBIT_LLM_TIMEOUT_S` is raised past 90 s,
    /// raise this with it.
    ///
    /// **It has to be applied in two places to mean anything.** `chatStream` sets it as the
    /// request's `timeoutInterval` *and* as its own watchdog interval. Setting only the
    /// watchdog was a no-op: `session` is a plain `URLSession(configuration: .ephemeral)`
    /// (`:56`), whose default `timeoutIntervalForRequest` is 60 s, so URLSession threw
    /// `NSURLErrorTimedOut` at 60 s and the watchdog at 150 s could never fire. A 75 s
    /// completion — comfortably inside the daemon's own 90 s budget — surfaced as a generic
    /// network error for work the daemon finished and, on BYOK/cloud, already billed. The
    /// two values must stay equal, which is why both read this constant rather than a
    /// literal.
    ///
    /// Note that for chat this is effectively a whole-request budget, not an inter-chunk
    /// one: `_stream_chat_sse` buffers the entire SSE body and length-frames it
    /// (`orbit/browser_bridge/server.py`), so not even the response headers land until the
    /// completion is done. The watchdog still earns its place — it covers a daemon that
    /// dies mid-body, where URLSession would keep waiting on a `Content-Length` that never
    /// arrives.
    static let chatStreamInactivityTimeout: TimeInterval = 150

    /// The tasks one `chatStream` owns, plus whether the stream has already terminated.
    /// Both fields are read and written under a single lock so a task can never enrol
    /// into a box that has already been drained.
    private struct ChildTasks: Sendable {
        var terminated = false
        var tasks: [Task<Void, Never>] = []
    }

    func chatStream(
        _ query: String,
        model: String?,
        appBundleId: String?,
        since: String?,
        until: String?
    ) -> AsyncThrowingStream<ChatChunk, Error> {
        AsyncThrowingStream { continuation in
            // Defence in depth behind the server-side framing fix (plan 52). Even with a
            // correct `Content-Length` and a `data: [DONE]` sentinel, a daemon that dies
            // mid-body would otherwise leave `bytes.lines` awaiting an EOF forever, and
            // `ChatStore.isStreaming` — the only input to the "thinking" spinner and to
            // `canSend` — never resets. Every read bumps `lastActivity`; the watchdog
            // cancels the reader and fails the stream if it stops moving.
            let lastActivity = OSAllocatedUnfairLock(initialState: Date())

            // `onTermination` is installed before either task starts, so there is no window
            // in which a task is running but unregistered. `children` is what makes that
            // possible: the tasks can't be named before they exist, so they enrol
            // themselves, and enrolling after termination has already fired cancels
            // immediately instead of leaking.
            let children = OSAllocatedUnfairLock(initialState: ChildTasks())
            func adopt(_ task: Task<Void, Never>) {
                let alreadyTerminated = children.withLock { box -> Bool in
                    if box.terminated { return true }
                    box.tasks.append(task)
                    return false
                }
                if alreadyTerminated { task.cancel() }
            }
            // Fires on normal finish, on the throwing finish below, and on consumer
            // cancellation, so neither task outlives the stream. `finish()` after a
            // `finish(throwing:)` is a no-op, so whichever task loses the race is harmless.
            continuation.onTermination = { _ in
                let running = children.withLock { box -> [Task<Void, Never>] in
                    box.terminated = true
                    defer { box.tasks.removeAll() }
                    return box.tasks
                }
                for task in running { task.cancel() }
            }

            let reader = Task {
                do {
                    var request = URLRequest(url: base.appendingPathComponent("/api/chat"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    if let token = OrbitPaths.loadBridgeToken() {
                        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    }
                    var body = ["query": query]
                    // Omit each key entirely when there is no value, so the daemon
                    // keeps using its configured default model / unscoped retrieval.
                    if let model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        body["model"] = model
                    }
                    if let appBundleId, !appBundleId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        body["app_bundle_id"] = appBundleId
                    }
                    if let since, !since.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        body["since"] = since
                    }
                    if let until, !until.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        body["until"] = until
                    }
                    request.httpBody = try JSONEncoder().encode(body)
                    // Same reasoning as `fetchDigest` (`:191-195`): URLSession's 60 s
                    // default would abort while the daemon is still inside its own 90 s
                    // completion budget, reporting a network error for work that succeeds
                    // and bills anyway. Shares the watchdog's constant so the two can't
                    // drift — see `chatStreamInactivityTimeout`.
                    request.timeoutInterval = Self.chatStreamInactivityTimeout
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw OrbitBridgeError.invalidResponse
                    }
                    guard http.statusCode == 200 else {
                        throw try await Self.bridgeError(from: bytes, statusCode: http.statusCode)
                    }
                    for try await line in bytes.lines {
                        lastActivity.withLock { $0 = Date() }
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" {
                            continuation.yield(ChatChunk(kind: .done))
                            break
                        }
                        if let chunk = Self.decodeSSEChunk(payload) {
                            continuation.yield(chunk)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            adopt(reader)

            let watchdog = Task {
                while !Task.isCancelled {
                    let idle = Date().timeIntervalSince(lastActivity.withLock { $0 })
                    let remaining = Self.chatStreamInactivityTimeout - idle
                    guard remaining > 0 else {
                        // Cancel first so the URLSession task tears the socket down, then
                        // report. Never resolve this silently: `sendViaBridge`'s catch is
                        // what turns this into a message the user can actually see.
                        reader.cancel()
                        continuation.finish(throwing: OrbitBridgeError.chatStreamStalled)
                        return
                    }
                    // Re-check only when the *current* deadline could have elapsed; a chunk
                    // arriving in the meantime pushes `remaining` back out on the next pass.
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
            }
            adopt(watchdog)
        }
    }

    private func postTaskAction<Body: Encodable, Response: Decodable>(
        id: Int64,
        pathSuffix: String,
        body: Body?,
        as _: Response.Type
    ) async throws -> Response {
        guard await checkStatus() else { throw OrbitBridgeError.daemonOffline }
        var request = URLRequest(url: base.appendingPathComponent("/api/task/\(id)/\(pathSuffix)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = OrbitPaths.loadBridgeToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = json["error"] as? String,
               !message.isEmpty {
                throw OrbitBridgeError.serverMessage(message)
            }
            throw OrbitBridgeError.invalidResponse
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    /// Every GET goes through here, and every GET now carries the bearer token.
    ///
    /// The pre-existing GETs (`/api/setup/status`, `/api/llm/models`, `/api/detect/status`,
    /// `/api/sessions/last`, `/api/privacy/status`) are open routes that ignore the header,
    /// so sending it unconditionally costs nothing. The plan 51 Phase 3A store routes are
    /// **not** open — they serve full captured atom text — and 401 without it
    /// (`docs/bridge-api-additions.md` §0.1). One header, no per-route bookkeeping.
    private func getJSON<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        guard await checkStatus() else { throw OrbitBridgeError.daemonOffline }
        let (data, response) = try await session.data(for: try authorizedGET(path, query: query))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OrbitBridgeError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// `URLQueryItem` percent-encodes for us, which matters for the timestamp bounds on
    /// `/api/atoms`: a literal `+` in `2026-08-14T20:00:00.000000+00:00` would decode to a
    /// space server-side and silently shift the textual comparison
    /// (`docs/bridge-api-additions.md` route 5).
    private func authorizedGET(_ path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        guard var components = URLComponents(
            url: base.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw OrbitBridgeError.invalidResponse
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw OrbitBridgeError.invalidResponse }
        var request = URLRequest(url: url)
        if let token = OrbitPaths.loadBridgeToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func postJSON<T: Decodable, B: Encodable>(
        _ path: String,
        body: B?,
        auth: Bool
    ) async throws -> T {
        guard await checkStatus() else { throw OrbitBridgeError.daemonOffline }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if auth, let token = OrbitPaths.loadBridgeToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Self.bridgeError(from: data, statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func bridgeError(from data: Data, statusCode: Int) -> OrbitBridgeError {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = json["error"] as? String,
           !message.isEmpty {
            return .serverMessage(message)
        }
        return .httpStatus(statusCode)
    }

    private static func bridgeError(
        from bytes: URLSession.AsyncBytes,
        statusCode: Int
    ) async throws -> OrbitBridgeError {
        var errorData = Data()
        errorData.reserveCapacity(512)
        for try await byte in bytes {
            errorData.append(byte)
            if errorData.count >= 4096 { break }
        }
        if let json = try? JSONSerialization.jsonObject(with: errorData) as? [String: Any],
           let message = json["error"] as? String,
           !message.isEmpty {
            return .serverMessage(message)
        }
        return .httpStatus(statusCode)
    }

    private static func decodeSSEChunk(_ payload: String) -> ChatChunk? {
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let text = json["text"] as? String {
            return ChatChunk(kind: .text(text))
        }
        if let hitsData = json["hits"],
           let data = try? JSONSerialization.data(withJSONObject: hitsData),
           let hits = try? JSONDecoder().decode([SearchHit].self, from: data) {
            return ChatChunk(kind: .sources(hits))
        }
        return nil
    }
}
