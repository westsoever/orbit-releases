import SwiftUI
import AppKit

/// Hover highlight for tappable rows. Fill + border only — never shadow,
/// never frame (plan 21 §0.9).
struct OrbitHoverHighlight: ViewModifier {
    var cornerRadius: CGFloat = OrbitShape.radiusControl
    var tint: Color? = nil          // nil → neutral; pass an accent for tinted rows
    var showsCursor: Bool = true

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: cornerRadius))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .animation(OrbitMotion.hover, value: isHovering)
            .onHover { hovering in
                isHovering = hovering
                guard showsCursor else { return }
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .onDisappear {
                // Guard against a view vanishing mid-hover and stranding the cursor.
                // Note: for views removed via .transition(...), this can fire before the
                // exit animation visually finishes, so the cursor may reset slightly
                // before the row has fully faded out. Accepted trade-off — the
                // alternative (tracking transition completion) isn't worth the
                // complexity for a cosmetic, sub-second gap.
                if isHovering && showsCursor { NSCursor.pop(); isHovering = false }
            }
    }

    private var fill: Color {
        guard isHovering else { return .clear }
        if let tint { return tint.opacity(colorScheme == .dark ? 0.16 : 0.09) }
        return Color.primary.opacity(colorScheme == .dark ? 0.07 : 0.045)
    }
}

extension View {
    func orbitHoverRow(
        cornerRadius: CGFloat = OrbitShape.radiusControl,
        tint: Color? = nil,
        showsCursor: Bool = true
    ) -> some View {
        modifier(OrbitHoverHighlight(cornerRadius: cornerRadius, tint: tint, showsCursor: showsCursor))
    }
}
