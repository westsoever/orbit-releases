import SwiftUI

struct TimeChip: View {
    let time: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(time)
            .font(.caption2.weight(.medium))
            .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.orbitDividerHairline(for: colorScheme), in: RoundedRectangle(cornerRadius: OrbitShape.radiusControl))
    }
}
