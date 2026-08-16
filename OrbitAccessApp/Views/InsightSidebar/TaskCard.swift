import AppKit
import SwiftUI

struct TaskCard: View {
    @Environment(AppViewModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    let task: TaskLogEntry

    @State private var isExpanded = false
    @State private var isDismissed = false
    @State private var errorMessage: String?
    @State private var isApproving = false

    private var agentType: AgentType {
        AgentType(rawValueOrNil: task.agentType) ?? .writing
    }

    var body: some View {
        if !isDismissed {
            // No accent bar: the agent signal lives on `AgentTypeBadge` in the header.
            SidecardRow(accent: .clear) {
                VStack(alignment: .leading, spacing: 8) {
                    header
                    bodyText
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(Color.orbitScoreRed)
                    }
                    actions
                }
            }
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            Text(task.title ?? "Untitled Task")
                .font(.body.weight(.medium))
                .kerning(-0.1)
                .lineLimit(isExpanded ? nil : 2)
            Spacer()
            AgentTypeBadge(agentType: agentType)
        }
    }

    @ViewBuilder
    private var bodyText: some View {
        if let description = task.description, !description.isEmpty {
            Text(description)
                .font(.callout)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                .kerning(-0.1)
                .lineLimit(isExpanded ? nil : 3)
                .orbitHoverRow(cornerRadius: OrbitShape.radiusChip)
                .onTapGesture { withAnimation(OrbitMotion.standard) { isExpanded.toggle() } }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            OrbitButton(
                label: "Approve",
                variant: .primary,
                isLoading: isApproving,
                action: approveTask
            )
            .disabled(!model.canUseLiveServices)
            .help(model.canUseLiveServices ? "Approve task" : "orbit must be online to approve")

            Button("Skip") {
                skipTask()
            }
            .buttonStyle(OrbitFlatButtonStyle(variant: .secondary))
            .disabled(!model.canUseLiveServices || isApproving)
            .help(model.canUseLiveServices ? "Skip task" : "orbit must be online to skip")

            Spacer()
        }
    }

    private func approveTask() {
        isApproving = true
        errorMessage = nil
        Task {
            let prompt = task.originalPrompt ?? task.title ?? ""
            do {
                try await model.taskStore.approve(task: task, prompt: prompt)
                withAnimation(OrbitMotion.collapse) {
                    isDismissed = true
                }
            } catch {
                errorMessage = error.localizedDescription
                isApproving = false
            }
        }
    }

    private func skipTask() {
        Task {
            do {
                try await model.taskStore.skip(task: task)
                withAnimation(OrbitMotion.collapse) {
                    isDismissed = true
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct TaskArtifactCard: View {
    @Environment(AppViewModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    let artifact: TaskArtifact

    @State private var copied = false

    private var agentType: AgentType {
        AgentType(rawValueOrNil: artifact.agentType) ?? .writing
    }

    var body: some View {
        // No accent bar: the agent signal lives on `AgentTypeBadge` in the header.
        SidecardRow(accent: .clear) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 6) {
                    Text(artifact.title ?? "Untitled Task")
                        .font(.body.weight(.medium))
                        .kerning(-0.1)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    // Agent signal moved off the 3pt bar and onto the badge,
                    // matching `TaskCard.header`.
                    AgentTypeBadge(agentType: agentType)
                    Text(phaseLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(phaseColor)
                        .lineLimit(1)
                        .fixedSize()
                }

                if let description = artifact.description, !description.isEmpty, artifact.phase == .queued {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                        .lineLimit(2)
                }

                if artifact.phase == .queued {
                    Text("Generating draft…")
                        .font(.caption)
                        .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                }

                if artifact.phase == .failed, let errorMessage = artifact.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(Color.orbitScoreRed)
                }

                if artifact.phase == .done {
                    resultPanel
                }

                HStack(spacing: 8) {
                    if artifact.phase == .done {
                        Button(copied ? "Copied" : "Copy") {
                            copyResult()
                        }
                        .buttonStyle(OrbitFlatButtonStyle(variant: .primary))

                        if artifact.resultPath != nil {
                            Button("Show in Finder") {
                                revealInFinder()
                            }
                            .buttonStyle(OrbitFlatButtonStyle(variant: .secondary))
                        }
                    }

                    Spacer()

                    if artifact.phase != .queued {
                        Button("Dismiss") {
                            withAnimation(OrbitMotion.collapse) {
                                model.taskStore.dismissArtifact(id: artifact.id)
                            }
                        }
                        .buttonStyle(OrbitFlatButtonStyle(variant: .secondary))
                    }
                }
            }
        }
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    private var phaseLabel: String {
        switch artifact.phase {
        case .queued: return "Running"
        case .done: return "Done"
        case .failed: return "Failed"
        }
    }

    private var phaseColor: Color {
        switch artifact.phase {
        case .queued: return Color.orbitSecondaryText(for: colorScheme)
        case .done: return .orbitScoreEmerald
        case .failed: return .orbitScoreRed
        }
    }

    @ViewBuilder
    private var resultPanel: some View {
        if let preview = artifact.resultPreview, !preview.isEmpty {
            Text(preview)
                .font(.callout)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                .lineLimit(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: OrbitShape.radiusControl)
                        .fill(Color.orbitSurfaceMuted(for: colorScheme))
                )
        } else {
            Text("Draft saved. Open the file to view the full result.")
                .font(.caption)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
        }
    }

    private func copyResult() {
        let text: String
        if let path = artifact.resultPath,
           let fileText = try? String(contentsOfFile: path, encoding: .utf8),
           !fileText.isEmpty {
            text = fileText
        } else {
            text = artifact.resultPreview ?? ""
        }
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
    }

    private func revealInFinder() {
        guard let path = artifact.resultPath else { return }
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
