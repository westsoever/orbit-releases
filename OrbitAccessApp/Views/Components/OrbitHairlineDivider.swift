import SwiftUI

struct OrbitHairlineDivider: View {
    @Environment(\.colorScheme) private var colorScheme
    var horizontalPadding: CGFloat = 12

    var body: some View {
        Rectangle()
            .fill(Color.orbitDividerHairline(for: colorScheme))
            .frame(height: OrbitShape.borderHairlineWidth)
            .padding(.horizontal, horizontalPadding)
    }
}

struct OrbitPaneHairline: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(Color.orbitDividerHairline(for: colorScheme))
            .frame(width: OrbitShape.borderHairlineWidth)
    }
}
