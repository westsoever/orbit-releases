import SwiftUI

struct MainChatView: View {
    @Environment(AppViewModel.self) private var model
    @AppStorage("sidebaneVisible") private var sidebaneVisible = true
    @AppStorage("insightVisible") private var insightVisible = true

    private var isLandingMode: Bool {
        model.chatStore.messages.isEmpty && !model.chatStore.isStreaming
    }

    var body: some View {
        Group {
            if isLandingMode {
                landingView
            } else {
                conversationView
            }
        }
        .animation(OrbitMotion.fade, value: isLandingMode)
        .padding(.leading, sidebaneVisible ? SidebaneMetrics.gutter : 0)
        .padding(.trailing, insightVisible ? SidecardMetrics.gutter : 0)
        .animation(OrbitMotion.collapse, value: sidebaneVisible)
        .animation(OrbitMotion.collapse, value: insightVisible)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: Bindable(model).showCloudAISettings) {
            CloudAISettingsView()
                .padding()
        }
    }

    private var landingView: some View {
        VStack {
            Spacer(minLength: 32)
            ChatHeroView()
            Spacer(minLength: 20)
            VStack(spacing: 12) {
                if model.shouldShowCloudAIEnablePrompt {
                    CloudAIEnableCard()
                }
                ChatInputBar(showSpinOff: true, isCompact: false)
                chatErrorBanner
            }
            .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
    }

    private var conversationView: some View {
        VStack(spacing: 8) {
            ChatMessageList(messages: model.chatStore.messages, isStreaming: model.chatStore.isStreaming)

            if let errorMessage = model.chatStore.errorMessage {
                chatErrorBannerContent(errorMessage)
                    .padding(.horizontal, 22)
            }

            ChatInputBar(showSpinOff: true, isCompact: true)
                .padding(.horizontal, 16)

            if model.shouldShowCloudAIEnablePrompt {
                CloudAIEnableCard()
                    .padding(.horizontal, 16)
            }
        }
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var chatErrorBanner: some View {
        if let errorMessage = model.chatStore.errorMessage {
            chatErrorBannerContent(errorMessage)
        }
    }

    private func chatErrorBannerContent(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(Color.orbitScoreRed)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
