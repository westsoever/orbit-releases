import AppKit
import SwiftUI

/// Full-window Timeline: the center-pane content the "Timeline" Sidebane row swaps in
/// (Plan 17 Phase 6.2), exactly like `KanbanBoardView` does for Tasks — a persistent
/// `mainContentMode` case, not a sheet.
///
/// Structural shape copied from `KanbanBoardView.swift`: top bar + hairline divider +
/// scrollable content, the `sidebaneVisible` leading-gutter padding + `OrbitMotion.collapse`
/// animation, `.background(Color.orbitCanvas(for:))`, `.onAppear`/`.onDisappear` fetch +
/// light-poll lifecycle. No trailing gutter: the Sidecard is already hidden in Timeline mode
/// via `MainWindowView.isSidecardVisible` (`insightVisible && mainContentMode == .chat`) —
/// nothing here needs to reserve room for it.
///
/// Row idiom (snippet + app/time caption, tappable to a `ContextAtomDetailSheet`) copied
/// from `Views/InsightSidebar/RecentNotesList.swift`.
struct TimelineView: View {
    @Environment(AppViewModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("sidebaneVisible") private var sidebaneVisible = true

    @State private var selectedDay = Date()
    @State private var sessions: [LastSessionInfo] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var expandedSessionIds: Set<Int> = []
    @State private var eventsBySession: [Int: [SearchHit]] = [:]
    @State private var loadingEventsForSessionId: Int?
    @State private var selectedAtom: SearchHit?
    @State private var pollTask: Task<Void, Never>?

    private var disabledReason: String? {
        if !model.canUseLiveServices {
            return "orbit's background service is not running, so it cannot read your sessions."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
            OrbitHairlineDivider(horizontalPadding: 0)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.leading, sidebaneVisible ? SidebaneMetrics.gutter : 0)
        .animation(OrbitMotion.collapse, value: sidebaneVisible)
        .onAppear {
            Task { await loadSessions() }
            startPolling()
        }
        .onDisappear {
            pollTask?.cancel()
            pollTask = nil
        }
        .onChange(of: selectedDay) { _, _ in
            expandedSessionIds.removeAll()
            eventsBySession.removeAll()
            Task { await loadSessions() }
        }
        .sheet(item: $selectedAtom) { atom in
            ContextAtomDetailSheet(atom: atom)
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("Timeline")
                .font(.title2.weight(.bold))
                .kerning(-0.2)

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                daySteppers
                if let disabledReason {
                    Text(disabledReason)
                        .font(.caption)
                        .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                } else if isLoading {
                    Text("Loading…")
                        .font(.caption)
                        .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                }
            }
        }
        .padding(16)
    }

    private var daySteppers: some View {
        HStack(spacing: 8) {
            Button {
                shiftDay(by: -1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)

            Text(Self.dayDisplayFormatter.string(from: selectedDay))
                .font(.callout.weight(.medium))
                .kerning(-0.1)
                .frame(minWidth: 96)

            Button {
                shiftDay(by: 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .disabled(isViewingToday)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let error = errorMessage {
            VStack {
                Spacer()
                Text(error)
                    .font(.callout)
                    .foregroundStyle(Color.orbitScoreRed)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if sessions.isEmpty {
            VStack {
                Spacer()
                Text(disabledReason ?? "No sessions yet")
                    .font(.callout)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(sessions) { session in
                        sessionRow(session)
                    }
                }
                .padding(16)
            }
        }
    }

    // MARK: - Session row

    private func sessionRow(_ session: LastSessionInfo) -> some View {
        let isExpanded = expandedSessionIds.contains(session.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                toggleExpanded(session)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    appIconView(bundleId: session.primaryBundleId)
                        .frame(width: 20, height: 20)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(timeRangeText(session))
                            .font(.caption2)
                            .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                        Text(session.title ?? session.primaryAppName ?? "Untitled session")
                            .font(.callout.weight(.medium))
                            .kerning(-0.1)
                            .lineLimit(1)
                        Text("\(session.primaryAppName ?? "Unknown app") · \(session.atomCount) atom\(session.atomCount == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                }
                .padding(12)
                .contentShape(Rectangle())
                .orbitHoverRow(cornerRadius: OrbitShape.radiusCard)
            }
            .buttonStyle(.plain)

            if isExpanded {
                OrbitHairlineDivider(horizontalPadding: 0)
                sessionEvents(session)
                    .padding(12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .orbitCardChrome(colorScheme: colorScheme)
    }

    @ViewBuilder
    private func sessionEvents(_ session: LastSessionInfo) -> some View {
        if loadingEventsForSessionId == session.id {
            LoadingIndicator()
        } else if let events = eventsBySession[session.id] {
            if events.isEmpty {
                Text("No captured text for this session.")
                    .font(.caption2)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(events) { hit in
                        eventRow(hit)
                    }
                }
            }
        } else {
            Text("Loading events…")
                .font(.caption2)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
        }
    }

    private func eventRow(_ hit: SearchHit) -> some View {
        Button {
            selectedAtom = hit
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(stripHTML(hit.snippetHtml))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text("\(hit.windowTitle ?? hit.appName) · \(shortTime(hit.timestamp))")
                    .font(.caption2)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .orbitHoverRow(cornerRadius: OrbitShape.radiusChip)
        }
        .buttonStyle(.plain)
        .help(stripHTML(hit.snippetHtml))
    }

    // MARK: - App icon (best-effort — falls back to a generic glyph)

    @ViewBuilder
    private func appIconView(bundleId: String?) -> some View {
        if let bundleId,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "app.dashed")
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
        }
    }

    // MARK: - Actions

    private func toggleExpanded(_ session: LastSessionInfo) {
        if expandedSessionIds.contains(session.id) {
            expandedSessionIds.remove(session.id)
            return
        }
        expandedSessionIds.insert(session.id)
        Task { await loadEvents(for: session) }
    }

    /// `GET /api/atoms` (plan 51 decision D1 — the daemon owns the database). `startedAt`
    /// and `endedAt` are passed through verbatim: they were copied from
    /// `context_events.timestamp` in the first place and the comparison is textual, so
    /// reformatting them would break the range. The `loadingEventsForSessionId` spinner is
    /// now load-bearing rather than decorative — this is a round-trip, not a local read.
    @MainActor
    private func loadEvents(for session: LastSessionInfo) async {
        guard eventsBySession[session.id] == nil else { return }
        loadingEventsForSessionId = session.id
        eventsBySession[session.id] = (try? await model.bridge.fetchAtomsInRange(
            since: session.startedAt,
            until: session.endedAt,
            limit: 50
        )) ?? []
        loadingEventsForSessionId = nil
    }

    private func shiftDay(by delta: Int) {
        guard let next = Calendar.current.date(byAdding: .day, value: delta, to: selectedDay) else { return }
        selectedDay = next
    }

    private var isViewingToday: Bool {
        Calendar.current.isDateInToday(selectedDay)
    }

    @MainActor
    private func loadSessions() async {
        guard model.canUseLiveServices else {
            sessions = []
            errorMessage = nil
            isLoading = false
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let response = try await model.bridge.fetchSessions(
                day: Self.dayKeyFormatter.string(from: selectedDay),
                limit: 100
            )
            sessions = response.sessions
        } catch {
            sessions = []
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Could not load sessions."
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if Task.isCancelled { return }
                await loadSessions()
            }
        }
    }

    // MARK: - Formatting

    private func timeRangeText(_ session: LastSessionInfo) -> String {
        guard let start = session.startedAt.orbitParsedDate else { return "" }
        let startText = Self.timeFormatter.string(from: start)
        guard let end = session.endedAt.orbitParsedDate else { return startText }
        return "\(startText) – \(Self.timeFormatter.string(from: end))"
    }

    private func shortTime(_ timestamp: String) -> String {
        guard let date = timestamp.orbitParsedDate else { return String(timestamp.suffix(8)) }
        return Self.timeFormatter.string(from: date)
    }

    private func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let dayDisplayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.dateFormat = "EEE, MMM d"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
