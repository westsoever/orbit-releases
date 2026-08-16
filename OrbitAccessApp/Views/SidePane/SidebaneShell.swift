import SwiftUI

/// Single elevated card wrapping all left-rail content: an in-card header with a
/// hide control, plus the rail body below.
struct SidebaneShell<Content: View>: View {
    @ViewBuilder var content: () -> Content

    @AppStorage("sidebaneVisible") private var sidebaneVisible = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content()
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .orbitOverlayChrome(cornerRadius: OrbitShape.radiusSidecard, colorScheme: colorScheme)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("orbit")
                .font(.callout.weight(.semibold))
                .kerning(-0.1)

            Spacer(minLength: 0)
        }
        .padding(12)
    }
}
