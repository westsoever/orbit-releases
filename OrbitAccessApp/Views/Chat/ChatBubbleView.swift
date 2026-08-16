import SwiftUI

struct ChatBubbleView: View {
    let message: ChatMessage
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedAtom: SearchHit?

    private let bubbleRadius = OrbitShape.radiusCard

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }
            bubbleContent
            if message.role != .user { Spacer(minLength: 60) }
        }
        .sheet(item: $selectedAtom) { atom in
            ContextAtomDetailSheet(atom: atom)
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
            Text(message.content)
                .font(.body)
                .kerning(-0.1)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background {
                    if message.role == .user {
                        RoundedRectangle(cornerRadius: bubbleRadius).fill(Color.orbitAccent(for: colorScheme))
                    } else {
                        RoundedRectangle(cornerRadius: bubbleRadius)
                            .fill(Color.orbitCardSurface(for: colorScheme))
                            .overlay(
                                RoundedRectangle(cornerRadius: bubbleRadius)
                                    .stroke(Color.orbitBorderHairline(for: colorScheme), lineWidth: OrbitShape.borderHairlineWidth)
                            )
                    }
                }
                .foregroundStyle(message.role == .user ? .white : .primary)

            if message.role == .assistant, !message.sourceAtoms.isEmpty {
                sourceChips
            }

            Text(message.timestamp, style: .time)
                .font(.caption2)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
        }
    }

    private var sourceChips: some View {
        FlowLayout(spacing: 6) {
            ForEach(message.sourceAtoms) { atom in
                ContextSourceChip(atom: atom) {
                    selectedAtom = atom
                }
            }
        }
    }
}
