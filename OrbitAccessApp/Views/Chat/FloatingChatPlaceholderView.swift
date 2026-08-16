import SwiftUI

struct FloatingChatPlaceholderView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("chatIsFloating") private var chatIsFloating = false
    @AppStorage("sidebaneVisible") private var sidebaneVisible = true
    @AppStorage("insightVisible") private var insightVisible = true

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.on.rectangle.slash")
                .font(.system(size: 48))
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
            Text("Chat is in a floating window")
                .font(.headline)
                .kerning(-0.1)
            Text("Your conversation continues in the detached chat window.")
                .font(.callout)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                .multilineTextAlignment(.center)
            Button("Return to main window") {
                returnToMainWindow()
            }
            .buttonStyle(OrbitFlatButtonStyle(variant: .primary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .padding(.leading, sidebaneVisible ? SidebaneMetrics.gutter : 0)
        .padding(.trailing, insightVisible ? SidecardMetrics.gutter : 0)
        .animation(OrbitMotion.collapse, value: sidebaneVisible)
        .animation(OrbitMotion.collapse, value: insightVisible)
        .background(Color.orbitCanvas(for: colorScheme))
    }

    private func returnToMainWindow() {
        chatIsFloating = false
        dismissWindow(id: "floating-chat")
    }
}
