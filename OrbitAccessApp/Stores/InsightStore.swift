import Foundation
import Observation
import Combine

@Observable
final class InsightStore {
    var productivityScore = ProductivityScore(
        inputs: ScoreInputs(taskCompletion: 0, focusDepth: 0, contextRichness: 0, captureConsistency: 0)
    )
    var calendarEvents: [CalendarEvent] = []
    var isCalendarConnected = false
    var routines: [RoutineBlock] = []
    var recentNotes: [SearchHit] = []
    var atomsCapturedToday = 0
    /// Transient error from Run now / routine mutations.
    var routineErrorMessage: String?

    // MARK: - Today digest (from `build_digest` via the bridge; never assembled here)

    var digestNarrative: String?
    /// `"llm"` when the daemon wrote a narrative, `"structured"` when it counted rows.
    var digestSource: String?
    var digestDay: String?
    var digestSessionCount = 0
    var digestEventCount = 0
    var digestAtomCount = 0
    var isDigestLoading = false
    var digestError: String?

    // MARK: - Resume ("last session", from `get_sessions`/`current_session` via the
    // bridge; zero LLM cost, no approval gate — Plan 17 Phase 5.5)

    var lastSessionTitle: String?
    var lastSessionSummary: String?
    var lastSessionAppName: String?
    var lastSessionBundleId: String?
    var lastSessionFiles: [String] = []
    var isLastSessionLoading = false
    var lastSessionError: String?

    /// Bumped on poll / sheet dismiss so list badges recompute against `Date()`.
    var statusTick: Date = Date()

    @ObservationIgnored private var aggregateTimer: AnyCancellable?
    /// Plan 51 decision D1: the aggregates and the Context Stream come from the daemon over
    /// localhost HTTP, never from a direct `~/.orbit/orbit.db` handle.
    @ObservationIgnored private var bridge: OrbitBridgeProtocol?
    @ObservationIgnored private var lastSeenAtomId: Int64 = 0
    @ObservationIgnored private let calendarProvider: any CalendarScheduleProvider = DisconnectedCalendarProvider()

    func configure(bridge: OrbitBridgeProtocol) {
        self.bridge = bridge
        reloadRoutines()
    }

    func startAggregatePolling() {
        aggregateTimer?.cancel()
        aggregateTimer = Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshAggregates()
            }
    }

    func refreshAggregates() {
        refreshCalendar()
        // Do not reload routines from disk here: RoutineStorage.load() coerces
        // .running → .idle (crash recovery), which would clear in-flight Run now
        // badges on every 30s poll / WAL tick. statusTick alone refreshes schedule badges.
        // Quantise to minute so observers are not invalidated every 30s with an
        // identical schedule context (Plan 26; RoutineList owned by Plan 27).
        bumpStatusTickIfMinuteChanged()
        guard let bridge else { return }
        // The two aggregates are now HTTP round-trips, so they cannot stay synchronous the
        // way the GRDB reads were. Everything above this line still runs synchronously on
        // the caller's turn; only the daemon reads are deferred.
        Task { @MainActor in await self.loadAggregates(bridge: bridge) }
    }

    /// `GET /api/score/inputs` + `GET /api/atoms/today` (`docs/bridge-api-additions.md`
    /// routes 4 and 3). Both are UTC-day scoped daemon-side, exactly as the SQL they
    /// replace was, so the menu-bar count does not move.
    ///
    /// A failed fetch leaves the previous value in place instead of writing 0: with the
    /// daemon as the only data source, a transient restart would otherwise blink the
    /// score and the atom count down to zero and back.
    @MainActor
    private func loadAggregates(bridge: OrbitBridgeProtocol) async {
        if let inputs = try? await bridge.fetchScoreInputs() {
            let next = ProductivityScore(inputs: inputs)
            if next.value != productivityScore.value {
                productivityScore = next
            }
        }
        if let atoms = try? await bridge.fetchAtomsCapturedToday(), atoms != atomsCapturedToday {
            atomsCapturedToday = atoms
        }
    }

    private func bumpStatusTickIfMinuteChanged() {
        let calendar = Calendar.current
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: Date()
        )
        guard let minuteDate = calendar.date(from: components) else { return }
        if statusTick != minuteDate {
            statusTick = minuteDate
        }
    }

    private func refreshCalendar() {
        let connected = calendarProvider.isConnected
        if connected != isCalendarConnected {
            isCalendarConnected = connected
        }
        Task { @MainActor in
            let events = (try? await calendarProvider.todayEvents()) ?? []
            if events.map(\.id) != calendarEvents.map(\.id)
                || events.map(\.title) != calendarEvents.map(\.title)
                || events.map(\.start) != calendarEvents.map(\.start)
                || events.map(\.end) != calendarEvents.map(\.end)
            {
                calendarEvents = events
            }
        }
    }

    @MainActor
    func refreshAggregates(bridge: OrbitBridgeProtocol) async {
        configure(bridge: bridge)
        refreshAggregates()
    }

    // MARK: - Today digest

    /// Fetch today's digest.
    ///
    /// **Cost rule — `useLLM: true` spends one `daily_digest` completion per call.**
    /// Exactly two callers may pass true: the first load after the app comes online
    /// (`AppViewModel.pollDaemonStatus`) and an explicit user refresh tap on the Today
    /// card. The 30s aggregate timer (`startAggregatePolling`), `refreshAggregates`, and
    /// the WAL watcher (`AppViewModel.startWALWatcher`) must never request the narrative —
    /// an idle app that quietly bills the model is how Plan 30's cost ceiling breaks.
    @MainActor
    func refreshDigest(bridge: OrbitBridgeProtocol, useLLM: Bool) async {
        guard !isDigestLoading else { return }
        isDigestLoading = true
        defer { isDigestLoading = false }
        do {
            try await loadDigest(bridge: bridge, useLLM: useLLM)
        } catch {
            // A failed narrative request must not leave the card empty: the
            // structured digest costs nothing, so fall back to it rather than
            // forfeiting the day's summary until the user pays for a retry.
            if useLLM, (try? await loadDigest(bridge: bridge, useLLM: false)) != nil {
                return
            }
            digestError = error.localizedDescription
        }
    }

    @MainActor
    private func loadDigest(bridge: OrbitBridgeProtocol, useLLM: Bool) async throws {
        // markdown: false — the card renders the narrative, not the auditable doc.
        let digest = try await bridge.fetchDigest(day: "today", markdown: false, llm: useLLM)
        digestNarrative = digest.narrative
        digestSource = digest.source
        digestDay = digest.day
        digestSessionCount = digest.sessionCount
        digestEventCount = digest.totalEvents ?? 0
        digestAtomCount = digest.totalAtoms ?? 0
        digestError = nil
    }

    // MARK: - Resume

    /// Zero-cost: no LLM call, no approval gate. Safe to call on every daemon
    /// online transition, unlike `refreshDigest(useLLM: true)`.
    @MainActor
    func loadLastSession(bridge: OrbitBridgeProtocol) async {
        guard !isLastSessionLoading else { return }
        isLastSessionLoading = true
        defer { isLastSessionLoading = false }
        do {
            let response = try await bridge.fetchLastSession()
            lastSessionTitle = response.session?.title
            lastSessionSummary = response.session?.summary
            lastSessionAppName = response.session?.primaryAppName
            lastSessionBundleId = response.session?.primaryBundleId
            lastSessionFiles = response.files
            lastSessionError = nil
        } catch {
            lastSessionError = error.localizedDescription
        }
    }

    /// Context Stream card. `incremental: true` asks only for atoms newer than the last one
    /// seen (`GET /api/notes/recent`); `false` reloads the tail (`/api/notes/recent/tail`).
    func refreshRecentNotes(incremental: Bool) {
        guard let bridge else { return }
        Task { @MainActor in await self.loadRecentNotes(incremental: incremental, bridge: bridge) }
    }

    @MainActor
    private func loadRecentNotes(incremental: Bool, bridge: OrbitBridgeProtocol) async {
        if incremental, lastSeenAtomId > 0 {
            let newNotes = (try? await bridge.fetchRecentNotes(afterId: lastSeenAtomId)) ?? []
            if !newNotes.isEmpty {
                recentNotes = Array((newNotes + recentNotes).prefix(10))
                lastSeenAtomId = Int64(recentNotes.map(\.atomId).max() ?? Int(lastSeenAtomId))
            }
            return
        }
        // A failed full reload keeps whatever is on screen: the card is a live tail, and
        // blanking it because one poll missed the daemon is worse than showing stale rows.
        guard let notes = try? await bridge.fetchRecentNotesTail() else { return }
        recentNotes = notes
        lastSeenAtomId = Int64(notes.map(\.atomId).max() ?? 0)
    }

    // MARK: - Routines

    func reloadRoutines() {
        routines = RoutineStorage.load()
    }

    func upsert(_ routine: RoutineBlock) {
        if let index = routines.firstIndex(where: { $0.id == routine.id }) {
            routines[index] = routine
        } else {
            routines.append(routine)
        }
        RoutineStorage.save(routines)
        statusTick = Date()
    }

    func delete(id: String) {
        routines.removeAll { $0.id == id }
        RoutineStorage.save(routines)
        statusTick = Date()
    }

    func markCompleted(id: String, at date: Date = Date()) {
        guard let index = routines.firstIndex(where: { $0.id == id }) else { return }
        routines[index].lastCompletedAt = date
        routines[index].runState = .idle
        RoutineStorage.save(routines)
        statusTick = Date()
    }

    func setRunState(id: String, _ state: RoutineRunState) {
        guard let index = routines.firstIndex(where: { $0.id == id }) else { return }
        routines[index].runState = state
        RoutineStorage.save(routines)
        statusTick = Date()
    }

    func routine(id: String) -> RoutineBlock? {
        routines.first { $0.id == id }
    }
}
