import SwiftUI

/// Row chrome matched to AgentShortcutRow — neutral muted fill, no hairline border.
/// Accent survives on the icon and the hover tint only.
/// Trailing chevron signals "opens a menu"; width reserved via `SidebaneMetrics.menuAffordanceWidth`.
struct SidePaneMenuRowLabel: View {
    let title: String
    let icon: String
    // `nil` means "use the accent for the current scheme" — a per-scheme default value can't be
    // expressed as a static default parameter (it needs `colorScheme`, which isn't available
    // until the view body runs), so the resolution happens in `resolvedIconColor` instead.
    var iconColor: Color? = nil

    @Environment(\.colorScheme) private var colorScheme

    private var resolvedIconColor: Color {
        iconColor ?? Color.orbitAccent(for: colorScheme)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(resolvedIconColor)
                .frame(width: 20)
            Text(title)
                .font(.callout)
                .foregroundStyle(.primary)
                .kerning(-0.1)
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                .frame(width: SidebaneMetrics.menuAffordanceWidth, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Color.orbitSurfaceMuted(for: colorScheme),
            in: RoundedRectangle(cornerRadius: OrbitShape.radiusControl)
        )
        .contentShape(Rectangle())
    }
}

/// History / Search trigger: draw AgentShortcutRow chrome ourselves, host `Menu` as an
/// invisible hit overlay so AppKit never replaces the custom label (`.menuStyle(.button)`
/// / `.borderlessButton` still synthesize native control chrome on macOS 14).
struct SidePaneDropdownTrigger<MenuContent: View>: View {
    let title: String
    let icon: String
    // Same `nil` = "resolve to the current scheme's accent" convention as `SidePaneMenuRowLabel`
    // above (see its comment) — needed here too since this view also feeds `iconColor` into
    // `.orbitHoverRow(tint:)`, which must match what the label renders.
    var iconColor: Color? = nil
    @ViewBuilder let menuContent: () -> MenuContent

    @Environment(\.colorScheme) private var colorScheme

    private var resolvedIconColor: Color {
        iconColor ?? Color.orbitAccent(for: colorScheme)
    }

    var body: some View {
        SidePaneMenuRowLabel(title: title, icon: icon, iconColor: resolvedIconColor)
            .overlay {
                Menu {
                    menuContent()
                } label: {
                    // Opaque-to-hit-testing, invisible fill sized by the overlay.
                    // Avoid Color.clear — AppKit Menu can collapse a clear label to zero.
                    Rectangle()
                        .fill(Color.primary.opacity(0.001))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
            }
            .orbitHoverRow(tint: resolvedIconColor)
    }
}
