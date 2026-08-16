import SwiftUI

/// Row styling copied from AgentShortcutRow (Views/SidePane/AgentShortcutRow.swift).
struct NewChatButton: View {
    @Environment(AppViewModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("mainContentMode") private var mainContentMode: MainContentMode = .chat

    var body: some View {
        Button {
            model.chatStore.newConversation()
            mainContentMode = .chat
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.body)
                    .foregroundStyle(Color.orbitAccent(for: colorScheme))
                    .frame(width: 20)
                Text("New Chat")
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .kerning(-0.1)
                Spacer(minLength: 0)
                Color.clear
                    .frame(width: SidebaneMetrics.menuAffordanceWidth)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                Color.orbitSurfaceMuted(for: colorScheme),
                in: RoundedRectangle(cornerRadius: OrbitShape.radiusControl)
            )
            .orbitHoverRow(tint: .orbitAccent(for: colorScheme))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.chatStore.isStreaming)
        .help("Start a new conversation")
    }
}
