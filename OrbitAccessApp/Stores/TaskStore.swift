import Foundation
import Observation
import Combine

struct TaskArtifact: Identifiable, Sendable {
    enum Phase: String, Sendable {
        case queued
        case done
        case failed
    }

    let id: Int64
    var title: String?
    var description: String?
    var agentType: String?
    var phase: Phase
    var resultPath: String?
    var resultPreview: String?
    var exitCode: Int?
    var errorMessage: String?
}

/// Lifecycle of one user-pressed detection run.
///
/// `empty` is deliberately not a failure: `detect_tasks` returning `[]` means the
/// confidence threshold rejected everything, which is the filter working.
enum DetectPhase: Equatable {
    case idle
    case running
    case empty
    case failed(String)
}

@Observable
final class TaskStore {
    var pendingTasks: [TaskLogEntry] = []
    var kanbanTasks: [TaskLogEntry] = []
    var artifacts: [TaskArtifact] = []
    var isLoading = false
    var lastError: String?
    var detectPhase: DetectPhase = .idle

    @ObservationIgnored private var timer: AnyCancellable?
    @ObservationIgnored private var bridge: OrbitBridgeProtocol?
    @ObservationIgnored private var liveServicesCheck: () -> Bool = { false }
    @ObservationIgnored private var pollingTaskIDs: Set<Int64> = []
    /// `isLoading` is only for the first paint; subsequent polls must not thrash it.
    @ObservationIgnored private var hasLoadedOnce = false

    /// Kanban-shaped grouping of `kanbanTasks` so `KanbanBoardView` stays dumb.
    var kanbanColumns: (
        detected: [TaskLogEntry], approved: [TaskLogEntry],
        done: [TaskLogEntry], failed: [TaskLogEntry], skipped: [TaskLogEntry]
    ) {
        let approved = kanbanTasks.filter { $0.status == "approved" }
        let dispatched = kanbanTasks.filter { $0.status == "dispatched" }
        return (
            detected: kanbanTasks.filter { $0.status == "detected" },
            approved: approved,
            done: dispatched.filter { $0.exitCode == 0 },
            failed: dispatched.filter { $0.exitCode != 0 },
            skipped: kanbanTasks.filter { $0.status == "skipped" }
        )
    }

    func configure(bridge: OrbitBridgeProtocol) {
        self.bridge = bridge
    }

    func startPolling(bridge: OrbitBridgeProtocol, liveServicesCheck: @escaping () -> Bool) {
        self.bridge = bridge
        self.liveServicesCheck = liveServicesCheck
        timer?.cancel()
        timer = Timer.publish(every: 5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { await self?.refresh(isDaemonOnline: self?.liveServicesCheck() ?? false) }
            }
        // Immediate first load — AppViewModel no longer refreshes tasks on every status tick.
        Task { await refresh(isDaemonOnline: liveServicesCheck()) }
    }

    @MainActor
    func refresh(isDaemonOnline: Bool) async {
        let showLoading = !hasLoadedOnce
        if showLoading {
            isLoading = true
        }
        defer {
            if showLoading {
                isLoading = false
            }
        }

        // No direct-SQLite fallback any more: plan 51 decision D1 makes the daemon the only
        // reader of the encrypted store, so "daemon offline" and "no tasks available" are the
        // same state and there is nothing else to try.
        let next: [TaskLogEntry]
        if isDaemonOnline, let bridge {
            next = await bridge.fetchPendingTasks()
        } else {
            next = []
        }

        if next.map(\.id) != pendingTasks.map(\.id)
            || next.map(\.status) != pendingTasks.map(\.status)
            || next.map(\.title) != pendingTasks.map(\.title)
        {
            pendingTasks = next
        }
        hasLoadedOnce = true
    }

    /// Kanban-shaped state for the full board view. Deliberately not wired into
    /// `startPolling`'s 5 s timer — the board is only one of several center-pane
    /// contents, so its owner (Phase 3/5's `.onAppear`/`.onDisappear`) decides when
    /// to call this, rather than paying for the query while chat is showing.
    @MainActor
    func refreshKanban(isDaemonOnline: Bool) async {
        let next: [TaskLogEntry]
        if isDaemonOnline, let bridge {
            next = await bridge.fetchKanbanTasks()
        } else {
            next = []
        }

        if next.map(\.id) != kanbanTasks.map(\.id)
            || next.map(\.status) != kanbanTasks.map(\.status)
            || next.map(\.title) != kanbanTasks.map(\.title)
        {
            kanbanTasks = next
        }
    }

    /// Ask the daemon to look at recent context and suggest tasks. User-pressed only —
    /// nothing schedules this, and `startPolling`'s 5 s timer never calls it.
    @MainActor
    func suggestTasks(sinceHours: Double = 8, refresh: Bool = false) async {
        guard let bridge else { return }
        // One run at a time; a second press while running would only earn a 409.
        guard detectPhase != .running else { return }
        detectPhase = .running
        do {
            _ = try await bridge.requestDetect(sinceHours: sinceHours, refresh: refresh)
        } catch OrbitBridgeError.detectAlreadyRunning {
            // A run started before this app launch (or from the CLI) is still going.
            // Follow it rather than reporting a failure the user cannot act on.
        } catch {
            detectPhase = .failed(error.localizedDescription)
            return
        }
        await pollDetectStatus(bridge: bridge)
    }

    @MainActor
    private func pollDetectStatus(bridge: OrbitBridgeProtocol) async {
        // Leave nothing stuck in .running if this task is cancelled — .running is also
        // the re-entry guard, so a stranded value would disable the button for good.
        defer {
            if detectPhase == .running {
                detectPhase = .idle
            }
        }
        // ~60 s: detection is a single completion, unlike pollTaskStatus's dispatched
        // agent run, and the daemon bounds it at ORBIT_LLM_TIMEOUT_S (default 90 s).
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let status: DetectStatusResponse
            do {
                status = try await bridge.fetchDetectStatus()
            } catch {
                detectPhase = .failed(error.localizedDescription)
                return
            }
            switch status.state {
            case "done":
                guard status.taskCount > 0 else {
                    detectPhase = .empty
                    return
                }
                // The 5 s poll would pick these up on its own; forcing one refresh here
                // just means the cards land with the button, not seconds later.
                await refresh(isDaemonOnline: liveServicesCheck())
                detectPhase = .idle
                return
            case "error":
                // The daemon's messages are already user-facing (no_captures, no_user,
                // model_output, llm) — render, don't reword.
                detectPhase = .failed(status.error ?? "orbit could not suggest tasks.")
                return
            default:
                continue
            }
        }
        detectPhase = .failed("orbit is still working on this. Check back in a moment.")
    }

    @MainActor
    func approve(task: TaskLogEntry, prompt: String) async throws {
        guard let bridge else { return }
        lastError = nil
        _ = try await bridge.approve(id: task.id, prompt: prompt)
        TelemetryService.shared.track("task_approved")
        upsertArtifact(
            TaskArtifact(
                id: task.id,
                title: task.title,
                description: task.description,
                agentType: task.agentType,
                phase: .queued
            )
        )
        await refresh(isDaemonOnline: liveServicesCheck())
        startStatusPolling(id: task.id, bridge: bridge)
    }

    @MainActor
    func approve(id: Int64, prompt: String, bridge: OrbitBridgeProtocol) async throws {
        lastError = nil
        let task = pendingTasks.first(where: { $0.id == id })
        _ = try await bridge.approve(id: id, prompt: prompt)
        TelemetryService.shared.track("task_approved")
        upsertArtifact(
            TaskArtifact(
                id: id,
                title: task?.title,
                description: task?.description,
                agentType: task?.agentType,
                phase: .queued
            )
        )
        await refresh(isDaemonOnline: liveServicesCheck())
        startStatusPolling(id: id, bridge: bridge)
    }

    /// Manual task entry from the Detected column's inline composer (Plan 42-B).
    /// Force one refresh afterward — same reasoning as `pollDetectStatus`'s post-detect
    /// refresh (:184-186) — so the card lands with the composer collapsing, not seconds
    /// later on the board's own poll.
    @MainActor
    func createTask(title: String) async {
        guard let bridge else { return }
        lastError = nil
        do {
            _ = try await bridge.createTask(title: title, description: nil)
        } catch {
            lastError = error.localizedDescription
            TelemetryService.shared.track("task_create_failed")
            return
        }
        TelemetryService.shared.track("task_created")
        await refreshKanban(isDaemonOnline: liveServicesCheck())
    }

    @MainActor
    func dismissArtifact(id: Int64) {
        artifacts.removeAll { $0.id == id }
        pollingTaskIDs.remove(id)
    }

    @MainActor
    func skip(task: TaskLogEntry) async throws {
        guard let bridge else { return }
        lastError = nil
        try await bridge.skip(id: task.id)
        TelemetryService.shared.track("task_rejected")
        await refresh(isDaemonOnline: liveServicesCheck())
    }

    @MainActor
    func skip(id: Int64, bridge: OrbitBridgeProtocol) async throws {
        lastError = nil
        try await bridge.skip(id: id)
        TelemetryService.shared.track("task_rejected")
        await refresh(isDaemonOnline: liveServicesCheck())
    }

    @MainActor
    private func upsertArtifact(_ artifact: TaskArtifact) {
        if let index = artifacts.firstIndex(where: { $0.id == artifact.id }) {
            artifacts[index] = artifact
        } else {
            artifacts.insert(artifact, at: 0)
        }
    }

    @MainActor
    private func startStatusPolling(id: Int64, bridge: OrbitBridgeProtocol) {
        guard !pollingTaskIDs.contains(id) else { return }
        pollingTaskIDs.insert(id)
        Task { await pollTaskStatus(id: id, bridge: bridge) }
    }

    @MainActor
    private func pollTaskStatus(id: Int64, bridge: OrbitBridgeProtocol) async {
        defer { pollingTaskIDs.remove(id) }
        // Async 202 approve — poll until worker writes result (up to ~3 min).
        for _ in 0..<90 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            do {
                let status = try await bridge.fetchTaskStatus(id: id)
                applyStatus(status)
                if status.status == "dispatched" {
                    return
                }
            } catch {
                if var existing = artifacts.first(where: { $0.id == id }) {
                    existing.phase = .failed
                    existing.errorMessage = error.localizedDescription
                    upsertArtifact(existing)
                }
                return
            }
        }
        if var existing = artifacts.first(where: { $0.id == id }), existing.phase == .queued {
            existing.phase = .failed
            existing.errorMessage = "Timed out waiting for task result."
            upsertArtifact(existing)
        }
    }

    @MainActor
    private func applyStatus(_ status: TaskStatusResponse) {
        var artifact = artifacts.first(where: { $0.id == status.id }) ?? TaskArtifact(
            id: status.id,
            title: status.title,
            phase: .queued
        )
        artifact.title = status.title ?? artifact.title
        artifact.exitCode = status.exitCode
        artifact.resultPath = status.resultPath
        artifact.resultPreview = status.resultPreview
        if status.status == "dispatched" {
            if status.exitCode == 0, status.resultPath != nil || status.resultPreview != nil {
                artifact.phase = .done
                artifact.errorMessage = nil
            } else {
                artifact.phase = .failed
                artifact.errorMessage = "Task finished without a usable result."
            }
        } else {
            artifact.phase = .queued
        }
        upsertArtifact(artifact)
    }
}
