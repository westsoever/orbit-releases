import SwiftUI

struct TaskCardList: View {
    @Environment(AppViewModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    private var isEmpty: Bool {
        model.taskStore.pendingTasks.isEmpty && model.taskStore.artifacts.isEmpty
    }

    private var detectPhase: DetectPhase { model.taskStore.detectPhase }
    private var isDetecting: Bool { detectPhase == .running }

    /// nil when Suggest tasks is usable; otherwise why it is not. Daemon offline and
    /// "no AI configured" are different problems and must read differently.
    private var disabledReason: String? {
        if !model.canUseLiveServices {
            return "orbit's background service is not running, so it cannot read your context."
        }
        // Checked before isLLMAvailable on purpose: llm_available() is only an
        // /api/tags probe, so an unpulled model reports available and would fail
        // at call time. The preflight hint is the one signal that knows better.
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
        VStack(alignment: .leading, spacing: 8) {
            suggestSection
            taskContent
        }
    }

    @ViewBuilder
    private var suggestSection: some View {
        Button {
            Task { await model.taskStore.suggestTasks() }
        } label: {
            // The label swaps in place rather than swapping the button out for a
            // LoadingIndicator, so the card's height does not jump mid-run (Plan 26).
            // Same in-button spinner idiom as OrbitIconButton's isLoading.
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
        .disabled(isDetecting || disabledReason != nil)
        .help(helpText)

        detectCaption
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

    @ViewBuilder
    private var taskContent: some View {
        if model.taskStore.isLoading && isEmpty {
            LoadingIndicator(label: "Loading tasks…")
        } else if isEmpty {
            // When a run just finished with nothing to suggest, detectCaption has
            // already said so — don't say it twice in two different words.
            if detectPhase != .empty {
                Text("No pending tasks")
                    .font(.caption)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                    .frame(maxWidth: .infinity)
                    // Match LoadingIndicator's vertical padding so empty↔loading
                    // never jumps ScrollView height (Plan 26 belt-and-braces).
                    .padding(.vertical, 12)
            }
        } else {
            VStack(spacing: 8) {
                ForEach(model.taskStore.artifacts) { artifact in
                    TaskArtifactCard(artifact: artifact)
                }
                ForEach(model.taskStore.pendingTasks) { task in
                    TaskCard(task: task)
                }
            }
        }
    }
}
