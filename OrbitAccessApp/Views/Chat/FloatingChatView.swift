import SwiftUI

struct FloatingChatView: View {
    @Environment(AppViewModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 8) {
            ChatMessageList(messages: model.chatStore.messages, isStreaming: model.chatStore.isStreaming)

            if let errorMessage = model.chatStore.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(Color.orbitScoreRed)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
            }

            ChatInputBar(showSpinOff: false, isCompact: true)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .background(Color.orbitCanvas(for: colorScheme))
        .frame(width: 360, height: 480)
    }
}
