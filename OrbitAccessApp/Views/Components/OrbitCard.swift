import SwiftUI

struct OrbitCard<Content: View>: View {
    var accent: Color = .clear
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // The accent bar is drawn as an overlay on the content rather than as an HStack
        // sibling. A bare `Color` is infinitely greedy on any axis it is not given, and
        // `.frame(width: 3)` only pins the width — so as a sibling it stretched to whatever
        // height was proposed and dragged the card with it. In a ZStack that is the full
        // window, which is why this card rendered as a full-height panel with a red edge
        // instead of a small notification. An overlay is sized by the content it decorates,
        // so the bar now matches the card and the card hugs its text.
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                if accent != .clear {
                    accent
                        .frame(width: 3)
                        .clipShape(RoundedRectangle(cornerRadius: 1.5))
                }
            }
            .orbitCardChrome(colorScheme: colorScheme)
    }
}
