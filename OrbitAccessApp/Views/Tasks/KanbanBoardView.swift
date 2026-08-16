import SwiftUI

/// Full-window Kanban board: the center-pane content the "Tasks" Sidebane row
/// swaps in (Plan 35 §3/§4). Five columns over `TaskStore.kanbanColumns`, all
/// reusing `TaskCard`/`TaskArtifactCard` from the Sidecard "Recommended Tasks"
/// widget verbatim — this view owns no approve/skip/dismiss logic of its own.
///
/// Column width is fixed (280pt) and the column row is a horizontal
/// `ScrollView`; at the 900×600 minimum window that means horizontal scroll,
/// which is expected (§5).
struct KanbanBoardView: View {
    @Environment(AppViewModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("sidebaneVisible") private var sidebaneVisible = true

    @State private var pollTask: Task<Void, Never>?

    /// Inline composer state for the Detected column's "Add task" button (Plan 42-B).
    /// Never a sheet/popover — the column expands in place and scrolls.
    @State private var isComposingTask = false
    @State private var newTaskTitle = ""
    @State private var isSubmittingTask = false

    private var detectPhase: DetectPhase { model.taskStore.detectPhase }
    private var isDetecting: Bool { detectPhase == .running }

    /// Same disabled-reason ladder as `TaskCardList` (`Views/InsightSidebar/TaskCardList.swift`)
    /// — daemon offline and "no AI configured" read differently, so don't collapse them.
    private var disabledReason: String? {
        if !model.canUseLiveServices {
            return "orbit's background service is not running, so it cannot read your context."
        }
        if let hint = model.localModelHint {
            return hint
        }
        if !model.isLLMAvailable {
            return "No AI is configured. Turn on Cloud AI or set up a local model in Settings."
        }
        return nil
    }

    private var helpText: String {
        if let reason = disabledReason { return reason }
        if isDetecting { return "orbit is reading your recent context." }
        return "Read the last 8 hours of context and suggest 1–3 tasks."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
            OrbitHairlineDivider(horizontalPadding: 0)
            boardColumns
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.leading, sidebaneVisible ? SidebaneMetrics.gutter : 0)
        .animation(OrbitMotion.collapse, value: sidebaneVisible)
        .onAppear {
            Task { await model.taskStore.refreshKanban(isDaemonOnline: model.canUseLiveServices) }
            startPolling()
        }
        .onDisappear {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("Tasks")
                .font(.title2.weight(.bold))
                .kerning(-0.2)

            Spacer()
        }
        .padding(16)
    }

    /// Moved into `detectedColumn` (Plan 42-B) rather than duplicated — same
    /// `disabledReason`/`helpText` ladder as before, and as `TaskCardList.swift:19-38`.
    private var scanButton: some View {
        Button {
            Task { await model.taskStore.suggestTasks() }
        } label: {
            // Label swaps in place rather than swapping the button for a
            // LoadingIndicator, matching TaskCardList's suggestSection.
            if isDetecting {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Looking at your context…")
                }
            } else {
                Text("Suggest tasks")
            }
        }
        .buttonStyle(OrbitFlatButtonStyle(variant: .secondary, size: .sm))
        .frame(maxWidth: .infinity)
        .disabled(isDetecting || disabledReason != nil)
        .help(helpText)
    }

    @ViewBuilder
    private var detectCaption: some View {
        switch detectPhase {
        case .empty:
            Text("Nothing clear enough to suggest from the last 8 hours.")
                .font(.caption)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(Color.orbitScoreRed)
                .fixedSize(horizontal: false, vertical: true)
        case .idle, .running:
            EmptyView()
        }
    }

    // MARK: - Columns

    private var boardColumns: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 16) {
                detectedColumn
                approvedColumn
                doneColumn
                failedColumn
                skippedColumn
            }
            .padding(16)
        }
    }

    /// Same `pendingTasks` array the Sidecard "Recommended Tasks" widget renders from
    /// (`TaskCardList.swift`), not `kanbanColumns.detected` — both surfaces show the
    /// literal same component backed by the literal same state, per §5.
    private var detectedColumn: some View {
        columnShell(title: "Detected", count: model.taskStore.pendingTasks.count) {
            detectedColumnControls
            if model.taskStore.pendingTasks.isEmpty {
                emptyColumnLabel
            } else {
                ForEach(model.taskStore.pendingTasks) { task in
                    KanbanRow { TaskCard(task: task) }
                }
            }
        }
    }

    /// Two full-column-width controls at the top of the Detected column (Plan 42-B):
    /// the inline "Add task" composer and the "Suggest tasks" button moved from the
    /// top-right. The composer expands the column's content — never a sheet/popover —
    /// so the column simply scrolls if it grows past the visible height.
    /// Both states stay mounted in the `ZStack` and swap via `.opacity` +
    /// `.allowsHitTesting`, never by conditional mounting — per program §5.2, a
    /// state flip that changes this column's content height by mounting/unmounting
    /// risks the NSHostingView `updateAnimatedWindowSize` abort.
    private var detectedColumnControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                addTaskButton
                    .opacity(isComposingTask ? 0 : 1)
                    .allowsHitTesting(!isComposingTask)
                taskComposer
                    .opacity(isComposingTask ? 1 : 0)
                    .allowsHitTesting(isComposingTask)
            }
            scanButton
            detectCaption
        }
    }

    private var addTaskButton: some View {
        Button("Add task") {
            isComposingTask = true
        }
        .buttonStyle(OrbitFlatButtonStyle(variant: .secondary, size: .sm))
        .frame(maxWidth: .infinity)
    }

    private var taskComposer: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("What needs doing?", text: $newTaskTitle)
                .textFieldStyle(.roundedBorder)
                .disabled(isSubmittingTask)
                .onSubmit { submitNewTask() }

            HStack(spacing: 8) {
                Button("Submit") { submitNewTask() }
                    .buttonStyle(OrbitFlatButtonStyle(variant: .primary, size: .sm))
                    .frame(maxWidth: .infinity)
                    .disabled(
                        isSubmittingTask
                            || newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )

                Button("Cancel") { cancelComposer() }
                    .buttonStyle(OrbitFlatButtonStyle(variant: .secondary, size: .sm))
                    .frame(maxWidth: .infinity)
                    .disabled(isSubmittingTask)
            }
        }
    }

    /// Empty/whitespace-only titles are never sent (program §4.1: the daemon 400s
    /// on a blank title anyway, but the composer should not round-trip to find that out).
    private func submitNewTask() {
        let title = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !isSubmittingTask else { return }
        isSubmittingTask = true
        Task {
            await model.taskStore.createTask(title: title)
            isSubmittingTask = false
            newTaskTitle = ""
            isComposingTask = false
        }
    }

    private func cancelComposer() {
        newTaskTitle = ""
        isComposingTask = false
    }

    private var approvedColumn: some View {
        let tasks = model.taskStore.kanbanColumns.approved
        return columnShell(title: "Approved", count: tasks.count) {
            if tasks.isEmpty {
                emptyColumnLabel
            } else {
                ForEach(tasks) { task in
                    if let artifact = runningArtifact(for: task.id) {
                        KanbanRow { TaskArtifactCard(artifact: artifact) }
                    } else {
                        KanbanRow { readOnlyRow(for: task) }
                    }
                }
            }
        }
    }

    private var doneColumn: some View {
        let tasks = model.taskStore.kanbanColumns.done
        return columnShell(title: "Done", count: tasks.count) {
            if tasks.isEmpty {
                emptyColumnLabel
            } else {
                ForEach(tasks) { task in
                    if let artifact = artifact(for: task.id, phase: .done) {
                        KanbanRow { TaskArtifactCard(artifact: artifact) }
                    } else {
                        KanbanRow {
                            readOnlyRow(for: task, statusLabel: "Done", statusColor: .orbitScoreEmerald)
                        }
                    }
                }
            }
        }
    }

    private var failedColumn: some View {
        let tasks = model.taskStore.kanbanColumns.failed
        return columnShell(title: "Failed", count: tasks.count) {
            if tasks.isEmpty {
                emptyColumnLabel
            } else {
                ForEach(tasks) { task in
                    if let artifact = artifact(for: task.id, phase: .failed) {
                        KanbanRow { TaskArtifactCard(artifact: artifact) }
                    } else {
                        KanbanRow {
                            readOnlyRow(for: task, statusLabel: "Failed", statusColor: .orbitScoreRed)
                        }
                    }
                }
            }
        }
    }

    /// Skip has no further lifecycle (§5) — no artifact matching, just the row.
    private var skippedColumn: some View {
        let tasks = model.taskStore.kanbanColumns.skipped
        return columnShell(title: "Skipped", count: tasks.count) {
            if tasks.isEmpty {
                emptyColumnLabel
            } else {
                ForEach(tasks) { task in
                    KanbanRow { readOnlyRow(for: task) }
                }
            }
        }
    }

    // MARK: - Column shell (flat container — no OrbitCard, no shadow)

    private func columnShell(
        title: String,
        count: Int,
        @ViewBuilder rows: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .kerning(-0.1)
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
            }

            ScrollView {
                VStack(spacing: 8) {
                    rows()
                }
            }
        }
        .frame(width: 280, alignment: .leading)
    }

    private var emptyColumnLabel: some View {
        Text("None yet")
            .font(.caption)
            .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
    }

    // MARK: - Artifact matching (keyed by `TaskArtifact.id == TaskLogEntry.id`,
    // set by `TaskStore.approve` — see `Stores/TaskStore.swift:206-217`)

    private func artifact(for id: Int64, phase: TaskArtifact.Phase) -> TaskArtifact? {
        model.taskStore.artifacts.first { $0.id == id && $0.phase == phase }
    }

    private func runningArtifact(for id: Int64) -> TaskArtifact? {
        artifact(for: id, phase: .queued)
    }

    // MARK: - Read-only row (no live artifact for this task in this session)

    private func readOnlyRow(
        for task: TaskLogEntry,
        statusLabel: String? = nil,
        statusColor: Color = .primary
    ) -> some View {
        KanbanReadOnlyRow(
            title: task.title ?? "Untitled Task",
            agentType: AgentType(rawValueOrNil: task.agentType) ?? .writing,
            statusLabel: statusLabel,
            statusColor: statusColor
        )
    }

    // MARK: - Polling (board-local; does not touch `TaskStore.startPolling`)

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { return }
                await model.taskStore.refreshKanban(isDaemonOnline: model.canUseLiveServices)
            }
        }
    }
}

/// Flat card chrome for board rows — background + hairline border, deliberately no
/// shadow (the project's only shadow token belongs to `SidecardShell`; this board is
/// not a sidecard, per §5's anti-pattern guard). Wraps `TaskCard`/`TaskArtifactCard`
/// (which render as flush `SidecardRow`s without their own chrome outside a
/// `SidecardShell`) and the read-only rows in the same flat surface language.
private struct KanbanRow<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background(
                Color.orbitCardSurface(for: colorScheme),
                in: RoundedRectangle(cornerRadius: OrbitShape.radiusCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: OrbitShape.radiusCard)
                    .stroke(
                        Color.orbitCardBorder(for: colorScheme),
                        lineWidth: OrbitShape.borderHairlineWidth
                    )
            )
    }
}

/// Read-only row for a `TaskLogEntry` with no corresponding in-memory `TaskArtifact` —
/// title, agent badge, and an optional status label (Done/Failed). No approve/skip
/// affordance: rows shown here are already past that stage or from a prior app session.
private struct KanbanReadOnlyRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let agentType: AgentType
    var statusLabel: String? = nil
    var statusColor: Color = .primary

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(title)
                .font(.body.weight(.medium))
                .kerning(-0.1)
                .lineLimit(2)
            Spacer(minLength: 4)
            AgentTypeBadge(agentType: agentType)
            if let statusLabel {
                Text(statusLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
