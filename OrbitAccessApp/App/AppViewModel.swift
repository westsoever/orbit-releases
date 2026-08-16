import Foundation
import Observation
import Combine

@MainActor
@Observable
final class AppViewModel {
    let chatStore = ChatStore()
    let taskStore = TaskStore()
    let insightStore = InsightStore()
    let usageInsightsStore = UsageInsightsStore()
    let privacyStore = PrivacyStore()
    let sidecardStore = SidecardStore()
    let userSession = UserSessionService.shared

    var isSignedIn: Bool { userSession.isSignedIn }

    var isDaemonOnline = false
    var isCaptureActive = false
    var isCapturePaused = false
    var isDatabaseReady = false
    var showPrivacyControls = false

    /// Plan 53 Phase 2 — drives the onboarding tour sheet on `MainWindowView`. Deliberately
    /// independent of `isSignedIn`: a local-only user is the default after Phase 1 and is
    /// exactly who the tour is for. `MainWindowView` raises it on first launch when the
    /// `hasCompletedTour` flag is unset; Settings raises it again on request.
    var showTour = false

    /// Plan 53 Phase 4 — drives the optional sign-in sheet on `MainWindowView`. Raised from
    /// Settings, and once after the tour completes; **never** on launch, and never as a
    /// precondition for anything (decision D2).
    var showSignIn = false

    /// Plan 53 Phase 6 — drives the optional profile questionnaire sheet on `MainWindowView`.
    /// Raised once after a successful sign-in, and again from Settings › Account on request.
    var showProfileQuestions = false

    /// The single gate on every profile-questionnaire affordance. The answers sync to the
    /// relay and live nowhere else, so a local-only Mac must never be asked: there would be
    /// nowhere to put them and no consent record. Mirror image of `canOfferCloudSignIn` —
    /// that one wants *no* cloud account, this one requires one.
    var canOfferProfileQuestions: Bool {
        UserAuthService.isCloudAuthEnabled && userSession.hasCloudAccount
    }

    /// The single gate on every sign-in affordance in the app. False whenever
    /// `ORBIT_CLOUD_AUTH_ENABLED` is off — which is the default, and stays the default
    /// until the relay is deployed (D4, risk R5) — and false again once this Mac's local
    /// user carries a `cloud_user_id`, because there is then nothing to sign into.
    var canOfferCloudSignIn: Bool {
        UserAuthService.isCloudAuthEnabled && !userSession.hasCloudAccount
    }

    /// Non-nil while the Edit/Create routine sheet is presented.
    var editingRoutine: RoutineBlock?
    var editingRoutineIsNew = false

    /// Historical data is available — i.e. the daemon is answering, since plan 51 decision D1
    /// makes it the only process that can read the encrypted `~/.orbit/orbit.db`.
    var canBrowseContext: Bool { isDatabaseReady }

    /// Hybrid search, LLM chat, capture indicator, task dispatch
    var canUseLiveServices: Bool { isDaemonOnline }

    /// Lexical search + offline snippet chat
    var canSearchLocally: Bool { canBrowseContext }

    /// AI streaming chat via bridge when the daemon is online (LLM routing happens in the daemon).
    var canUseAIChat: Bool { canUseLiveServices }

    var hasConfiguredAI: Bool {
        aiMode != nil || cloudAI.hasBYOK() || isLLMAvailable
    }

    /// User's explicit provider choice from ``~/.orbit/.env`` (not the daemon's auto-resolved provider).
    var userAIMode: AIMode? {
        LLMPreferencesService.shared.currentMode()
    }
    var isCloudAIEnabled = false
    var aiMode: AIMode?
    var localModelName: String?
    var isLLMAvailable = false
    var effectiveLLMProvider: String?
    var showCloudAISettings = false
    /// Non-nil only while the daemon has been proven unreachable — never for a database
    /// fault, because this app no longer opens a database (plan 51 decision D1). It is set
    /// after a poll that finds the daemon down *and* is not itself a start attempt, so a
    /// normal launch (during which the daemon takes a few seconds to come up) never shows it.
    var daemonConnectionFailure: OrbitBridgeError?
    var daemonControlState: DaemonControlState = .offline

    /// True when Accessibility, daemon, or LLM path needs attention.
    var setupNeedsAttention: Bool {
        !AccessibilityPermissions.isTrusted
            || !isDaemonOnline
            || !(isLLMAvailable || cloudAI.hasBYOK() || isCloudAIEnabled)
            || isCapturePaused
    }

    var seriousIssue: OrbitIssue? {
        guard let failure = daemonConnectionFailure else { return nil }
        return .daemonUnreachable(message: failure.localizedDescription)
    }

    let bridge = OrbitBridgeClient()
    let cloudAI = CloudAIService.shared
    private let daemonManager: DaemonManager

    @ObservationIgnored private let walWatcher = WALWatcher()
    @ObservationIgnored private var statusTimer: AnyCancellable?
    @ObservationIgnored private var hasPolledDaemonOnce = false
    @ObservationIgnored private var didAutoStartDaemonOnLaunch = false
    @ObservationIgnored private var didRequestDigestNarrative = false
    @ObservationIgnored private var didRequestLastSession = false

    var isDaemonStarting: Bool {
        if case .starting = daemonControlState { return true }
        return false
    }

    init() {
        daemonManager = DaemonManager(bridge: bridge)
        chatStore.configure(bridge: bridge)
        taskStore.configure(bridge: bridge)
        insightStore.configure(bridge: bridge)
        usageInsightsStore.configure(bridge: bridge)
        privacyStore.configure(bridge: bridge)
        refreshAIState()
    }

    func refreshAIState() {
        isCloudAIEnabled = cloudAI.isEnabled()
        aiMode = LLMPreferencesService.shared.currentMode()
        localModelName = LLMPreferencesService.shared.localModelName()
        if bridge.isDaemonAlive {
            isLLMAvailable = bridge.llmAvailable ?? false
            effectiveLLMProvider = bridge.llmProvider
        } else {
            isLLMAvailable = false
            effectiveLLMProvider = nil
        }
    }

    /// Poll daemon status until the resolved provider matches the saved mode, or time out.
    func confirmProviderSwitch(expectedMode: AIMode, timeoutSeconds: Double = 5) async throws {
        refreshAIState()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if providerMatches(expectedMode) {
                refreshAIState()
                return
            }
            _ = await bridge.checkStatus()
            refreshAIState()
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        throw LLMPreferencesError.providerSwitchTimeout
    }

    private func providerMatches(_ mode: AIMode) -> Bool {
        guard let provider = bridge.llmProvider else { return false }
        switch mode {
        case .local:
            return provider == "local"
        case .cloud:
            return provider == "relay"
        case .byok:
            return provider == "byok"
        }
    }

    /// Env-configured local model name, falling back to daemon-reported name.
    var effectiveLocalModelName: String? {
        localModelName ?? bridge.localModel
    }

    /// Daemon-side preflight: set only when the configured local model is missing or
    /// Ollama is down, so a nil here means "nothing to warn about".
    var localModelHint: String? {
        bridge.localModelReady == false ? bridge.localModelHint : nil
    }

    /// Mirrored out of the bridge client, which is a plain class: assigning to its properties
    /// invalidates no view. Views read this and never reach into `bridge` themselves.
    private(set) var daemonBuild: DaemonBuildInfo?

    /// nil when there is nothing to say — daemon offline, or older than the build-info fields.
    var buildProvenance: BuildProvenance? {
        BuildProvenance.resolve(daemon: daemonBuild)
    }

    func refreshCloudAIState() {
        refreshAIState()
    }

    var shouldShowCloudAIEnablePrompt: Bool {
        isDaemonOnline && !hasConfiguredAI
    }

    @MainActor
    func start() async {
        userSession.reloadFromDisk()
        // Plan 53 Phase 1: no `guard isSignedIn`. Capture must start for local-only
        // users — the daemon creates the local identity itself, and gating start()
        // on a session would mean nothing ever starts to create one.
        chatStore.loadHistory()
        sidecardStore.load()
        // Was `dbReader.bootstrap()`: an attempt to open `~/.orbit/orbit.db` with GRDB, which
        // is built against system SQLite and therefore cannot read the SQLCipher pages the
        // daemon writes. It threw `SQLITE_NOTADB` on every launch, and the `catch` skipped the
        // three calls below — which is why the error card was permanent *and* the sidebar was
        // empty. The reachability check that replaces it is what those reads actually need.
        await refreshDataAvailability(isDaemonReachable: await bridge.checkStatus())
        await ensureDaemonRunningOnLaunch()
        startStatusPolling()
        await startDaemon()
        taskStore.startPolling(bridge: bridge) { [weak self] in
            self?.canUseLiveServices ?? false
        }
        insightStore.startAggregatePolling()
    }

    @MainActor
    func completeSignUp() {
        userSession.reloadFromDisk()
        Task {
            await start()
        }
    }

    @MainActor
    func signOut() async {
        if isDaemonOnline {
            await stopDaemon()
        }
        try? userSession.signOut()
        isDatabaseReady = false
        daemonConnectionFailure = nil
        // Signing out is not quitting: the window stays open on the product. The daemon was
        // just stopped, so it must be allowed to auto-start again — otherwise
        // `ensureDaemonRunningOnLaunch()` short-circuits on the launch-time latch and capture
        // never resumes. (The daemon no longer *refuses* to run without a session; since plan
        // 53 Phase 1 it mints a local identity instead. Phase 5 defines the sign-out contract.)
        didAutoStartDaemonOnLaunch = false
    }

    /// The issue card's Retry.
    ///
    /// The old `retryDatabaseBootstrap()` re-ran the identical failing GRDB open, so
    /// it could never succeed. This one reconnects, and if the daemon really is down it starts
    /// it — the same path the sidebar's Start control uses — so pressing Retry can actually
    /// change the outcome.
    @MainActor
    func retryDaemonConnection() async {
        daemonConnectionFailure = nil
        if await bridge.checkStatus() {
            await refreshDataAvailability(isDaemonReachable: true)
            await pollDaemonStatus()
            return
        }
        await startDaemon(notifyOnSuccess: false)
        await refreshDataAvailability(isDaemonReachable: await bridge.checkStatus())
    }

    /// Single place that turns "is the daemon answering?" into the app's data state.
    ///
    /// On the way up it clears the issue, marks the store readable and fires the three loads
    /// the old bootstrap's `catch` used to skip. On the way down it only records the failure —
    /// the last-known aggregates and notes stay on screen rather than blanking.
    @MainActor
    private func refreshDataAvailability(isDaemonReachable: Bool) async {
        guard isDaemonReachable else {
            isDatabaseReady = false
            return
        }
        daemonConnectionFailure = nil
        isDatabaseReady = true
        insightStore.refreshAggregates()
        insightStore.refreshRecentNotes(incremental: false)
        startWALWatcher()
    }

    @MainActor
    func startDaemon(notifyOnSuccess: Bool = true) async {
        do {
            try await daemonManager.start()
            daemonControlState = daemonManager.controlState
            await pollDaemonStatus(notifyIfOnline: notifyOnSuccess)
        } catch {
            daemonControlState = daemonManager.controlState
        }
    }

    @MainActor
    func stopDaemon() async {
        do {
            try await daemonManager.stop()
            daemonControlState = daemonManager.controlState
            await pollDaemonStatus(notifyIfOffline: true)
        } catch {
            daemonControlState = daemonManager.controlState
        }
    }

    @MainActor
    func aiContext() -> AIFunctionContext {
        AIFunctionContext(
            chatStore: chatStore,
            canBrowseContext: canBrowseContext,
            canUseLiveServices: canUseLiveServices
        )
    }

    // MARK: - Sidebane nav

    /// Leaving chat hides the Sidecard (`MainWindowView.isSidecardVisible`), so commit any
    /// in-flight widget edit first — otherwise `isEditing` stays true on an invisible Sidecard
    /// and ⌘E is disabled on whatever pane comes up next, leaving no way to finish the edit
    /// until the user returns to chat (Plan 35 Task 3 Step 1). Shared by every Sidebane nav
    /// row that can switch `mainContentMode` away from `.chat` (`TasksTabRow`, `TimelineTabRow`).
    func commitSidecardEditIfLeavingChat(from mode: MainContentMode) {
        if mode == .chat, sidecardStore.isEditing {
            sidecardStore.commitEditing()
        }
    }

    // MARK: - Routines

    func beginCreateRoutine() {
        editingRoutineIsNew = true
        editingRoutine = RoutineBlock.blank()
    }

    func beginEditRoutine(_ routine: RoutineBlock) {
        editingRoutineIsNew = false
        editingRoutine = routine
    }

    func dismissRoutineEditor() {
        editingRoutine = nil
        editingRoutineIsNew = false
        // Do not reload routines from disk: RoutineStorage.load() coerces
        // .running → .idle (crash recovery), which would clear in-flight Prepare
        // badges when the edit sheet closes during/after Prepare in chat.
        insightStore.statusTick = Date()
    }

    /// Prepare in chat MVP: GET /api/digest + chat prefill. Does **not** mark
    /// completed — ChatStore has no send/answer completion signal yet, and
    /// prefill is not a run (Plan 27 Phase 1).
    @MainActor
    func runRoutine(id: String) async {
        guard let routine = insightStore.routine(id: id) else { return }
        insightStore.routineErrorMessage = nil
        insightStore.setRunState(id: id, .running)

        do {
            let digest = try await bridge.fetchDigest(day: "today", markdown: true)
            let context = digest.markdown ?? digest.narrative
            // `routine.model` (nil = app default) rides along with the prefill and is
            // honoured on the next send — see ChatStore.pendingModelOverride.
            chatStore.prefillInput(
                Self.routineRunPrompt(routine: routine, digestMarkdown: context),
                model: routine.model
            )
            chatStore.requestFocus()
            // Prepared, not completed — user still must send the message.
            insightStore.setRunState(id: id, .idle)
            if routine.notifyOnReady {
                DaemonNotificationService.shared.notifyRoutineReady(title: routine.title)
            }
        } catch {
            insightStore.setRunState(id: id, .idle)
            // Prefill instructions so the user can still run manually; do not mark completed.
            chatStore.prefillInput(
                Self.routineRunPrompt(routine: routine, digestMarkdown: nil),
                model: routine.model
            )
            chatStore.requestFocus()
            insightStore.routineErrorMessage = error.localizedDescription
        }
        insightStore.statusTick = Date()
    }

    private static func routineRunPrompt(routine: RoutineBlock, digestMarkdown: String?) -> String {
        var parts: [String] = []
        let title = routine.title.isEmpty ? "Routine" : routine.title
        parts.append("Run routine: \(title)")
        let instructions = routine.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instructions.isEmpty {
            parts.append(instructions)
        }
        if let digestMarkdown, !digestMarkdown.isEmpty {
            parts.append("---\nToday's digest context:\n\(digestMarkdown)")
        }
        return parts.joined(separator: "\n\n")
    }

    private func startStatusPolling() {
        statusTimer?.cancel()
        statusTimer = Timer.publish(every: 5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { await self?.pollDaemonStatus() }
            }
        Task { await pollDaemonStatus() }
    }

    @MainActor
    private func pollDaemonStatus(notifyIfOnline: Bool = false, notifyIfOffline: Bool = false) async {
        let wasOnline = isDaemonOnline
        isDaemonOnline = await bridge.checkStatus()
        isCaptureActive = bridge.captureActive
        isCapturePaused = bridge.capturePaused
        daemonBuild = bridge.daemonBuild
        refreshAIState()
        daemonManager.syncControlState(isOnline: isDaemonOnline, isCaptureActive: isCaptureActive)
        daemonControlState = daemonManager.controlState
        // Plan 26: TaskStore owns its 5s refresh cadence. Only force a refresh when
        // the daemon flips offline→online so the task list catches up immediately. That
        // same edge is what makes the store readable, so it also re-arms the WAL watcher
        // and refills the sidebar's aggregates / Context Stream — edge-triggered, because
        // `refreshDataAvailability` restarts the file-event source.
        if !wasOnline, isDaemonOnline {
            await taskStore.refresh(isDaemonOnline: true)
            await refreshDataAvailability(isDaemonReachable: true)
        } else if !isDaemonOnline {
            isDatabaseReady = false
            // Not on the first poll and not while a start is in flight: launching the app
            // legitimately spends a few seconds with no daemon, and an error card that
            // appears and disappears every launch is noise, not a signal.
            if hasPolledDaemonOnce, !isDaemonStarting {
                daemonConnectionFailure = .daemonOffline
            }
        }
        // First load only. This is one of exactly two places allowed to ask for the LLM
        // narrative (the other is the Today card's refresh tap) — see
        // InsightStore.refreshDigest. Keyed off the flag rather than the offline→online
        // edge because ensureDaemonRunningOnLaunch already sets isDaemonOnline when the
        // daemon was up before the app started. Detached so a slow completion never
        // stretches the 5s status poll.
        if isDaemonOnline, !didRequestDigestNarrative {
            didRequestDigestNarrative = true
            Task { await insightStore.refreshDigest(bridge: bridge, useLLM: true) }
        }
        // Zero-cost (no LLM, no approval gate), so this only needs the same
        // once-per-launch guard as the digest narrative, not its cost gating.
        if isDaemonOnline, !didRequestLastSession {
            didRequestLastSession = true
            Task { await insightStore.loadLastSession(bridge: bridge) }
        }

        if notifyIfOnline, isDaemonOnline {
            DaemonNotificationService.shared.notifyDaemonStarted()
        } else if notifyIfOffline, !isDaemonOnline {
            DaemonNotificationService.shared.notifyDaemonStopped()
        } else if hasPolledDaemonOnce, wasOnline, !isDaemonOnline {
            DaemonNotificationService.shared.notifyDaemonStopped()
        }

        hasPolledDaemonOnce = true
    }

    @MainActor
    private func ensureDaemonRunningOnLaunch() async {
        guard !didAutoStartDaemonOnLaunch else { return }
        didAutoStartDaemonOnLaunch = true

        if await bridge.checkStatus() {
            isDaemonOnline = true
            isCaptureActive = bridge.captureActive
            refreshAIState()
            daemonControlState = .running
            return
        }

        await startDaemon(notifyOnSuccess: false)
    }

    /// Kept, deliberately, as a pure file-event refresh trigger.
    ///
    /// `WALWatcher` never opens SQLite — it is `open(O_EVTONLY)` plus a
    /// `DispatchSourceFileSystemObject` — so encryption does not affect it, and the WAL file
    /// still ticks on every daemon write. That makes it a zero-cost "something was captured"
    /// signal that no amount of polling could match: the alternative would be a second timer
    /// on top of `InsightStore`'s 30 s aggregate poll, which is strictly more work for a
    /// strictly worse latency. What changes is when it arms — previously only after a
    /// successful database open, which is exactly why it never armed at all; now on daemon
    /// reachability.
    ///
    /// Known limitation, unchanged from before: the descriptor follows the inode, so a WAL
    /// checkpoint that recreates the file stops the events. The 30 s poll is the backstop.
    private func startWALWatcher() {
        let walURL = OrbitPaths.databaseURL
            .deletingLastPathComponent()
            .appendingPathComponent("orbit.db-wal")
        guard FileManager.default.fileExists(atPath: walURL.path) else { return }
        walWatcher.start(walURL: walURL) { [weak self] in
            Task { @MainActor in
                self?.insightStore.refreshRecentNotes(incremental: true)
                self?.insightStore.refreshAggregates()
            }
        }
    }
}
