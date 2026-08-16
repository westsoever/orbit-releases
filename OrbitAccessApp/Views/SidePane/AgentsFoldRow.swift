import SwiftUI

/// Header row for the folded "Agents" group in `SidebaneView` (Plan 44 item 1) — replaces
/// the four standalone agent rows with one row that expands in place to reveal them.
/// Chrome matched to `SidePaneMenuRowLabel`, but the trailing affordance is a chevron that
/// rotates on expand (idiom copied from `SidecardShell.headerRow`, `OrbitMotion.collapse`)
/// rather than the static up/down chevron a dropdown trigger uses — this is an inline fold,
/// not a menu.
struct AgentsFoldRow: View {
    @Binding var isExpanded: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button {
            withAnimation(OrbitMotion.collapse) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .font(.body)
                    .foregroundStyle(Color.orbitAccent(for: colorScheme))
                    .frame(width: 20)
                Text("Agents")
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .kerning(-0.1)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(OrbitMotion.collapse, value: isExpanded)
                    .frame(width: SidebaneMetrics.menuAffordanceWidth, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                Color.orbitSurfaceMuted(for: colorScheme),
                in: RoundedRectangle(cornerRadius: OrbitShape.radiusControl)
            )
            .orbitHoverRow(tint: Color.orbitAccent(for: colorScheme))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
