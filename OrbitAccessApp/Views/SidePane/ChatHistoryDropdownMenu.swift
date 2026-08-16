import SwiftUI

/// History menu via SidePaneDropdownTrigger (row chrome matched to AgentShortcutRow).
struct ChatHistoryDropdownMenu: View {
    @Environment(AppViewModel.self) private var model
    @AppStorage("mainContentMode") private var mainContentMode: MainContentMode = .chat

    private var conversations: [ChatConversation] {
        model.chatStore.history.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        SidePaneDropdownTrigger(title: "History", icon: "clock.arrow.circlepath") {
            if conversations.isEmpty {
                Button("No past conversations") {}
                    .disabled(true)
            } else {
                ForEach(conversations) { conversation in
                    Button(conversation.title) {
                        model.chatStore.openConversation(id: conversation.id)
                        mainContentMode = .chat
                    }
                }
            }
        }
    }
}
