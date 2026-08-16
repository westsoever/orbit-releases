import SwiftUI

struct ChatSuggestionChips: View {
    @Environment(AppViewModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @State private var isExpanded = false

    private static let staticSuggestions = [
        "Summarize what I worked on today",
        AgentType.research.chatTemplate,
        "Draft a status update email",
        "What should I focus on next?",
    ]

    private var allSuggestions: [String] {
        let taskTitles = model.taskStore.pendingTasks
            .prefix(2)
            .compactMap { task -> String? in
                if let title = task.title, !title.isEmpty { return title }
                if let description = task.description, !description.isEmpty { return description }
                if let prompt = task.originalPrompt, !prompt.isEmpty { return prompt }
                return nil
            }

        var result = Array(taskTitles)
        for suggestion in Self.staticSuggestions where !result.contains(suggestion) {
            result.append(suggestion)
        }
        return result
    }

    private var visibleSuggestions: [String] {
        isExpanded ? allSuggestions : Array(allSuggestions.prefix(4))
    }

    private var showMoreButton: Bool {
        allSuggestions.count > 4
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(visibleSuggestions.enumerated()), id: \.offset) { _, text in
                    suggestionChip(text)
                }
                if showMoreButton {
                    moreSuggestionsChip
                }
            }
        }
    }

    private func suggestionChip(_ text: String) -> some View {
        Button {
            model.chatStore.prefillInput(text)
            model.chatStore.requestFocus()
        } label: {
            // Agent-template chips ("Research: ") carry a trailing space because that value is
            // also the prefill text; trim it for display only so the chip padding stays even.
            Text(text.trimmingCharacters(in: .whitespaces))
                .font(.callout)
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(chipFill, in: RoundedRectangle(cornerRadius: OrbitShape.radiusChip))
                .overlay(
                    RoundedRectangle(cornerRadius: OrbitShape.radiusChip)
                        .stroke(chipBorder, lineWidth: OrbitShape.borderHairlineWidth)
                )
                .orbitHoverRow(cornerRadius: OrbitShape.radiusChip)
        }
        .buttonStyle(.plain)
    }

    private var moreSuggestionsChip: some View {
        Button {
            withAnimation(OrbitMotion.selection) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "sparkle")
                    .font(.caption)
                Text(isExpanded ? "Fewer suggestions" : "More suggestions")
                    .font(.callout)
            }
            .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(chipFill, in: RoundedRectangle(cornerRadius: OrbitShape.radiusChip))
            .overlay(
                RoundedRectangle(cornerRadius: OrbitShape.radiusChip)
                    .stroke(chipBorder, lineWidth: OrbitShape.borderHairlineWidth)
            )
            .orbitHoverRow(cornerRadius: OrbitShape.radiusChip)
        }
        .buttonStyle(.plain)
    }

    private var chipFill: Color {
        Color.orbitCardSurface(for: colorScheme)
    }

    private var chipBorder: Color {
        Color.orbitBorderHairline(for: colorScheme)
    }
}
