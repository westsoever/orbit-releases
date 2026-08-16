import SwiftUI

/// Layout constants for the floating sidecard overlay and the chat gutter it reserves.
enum SidecardMetrics {
    static let columnWidth: CGFloat = 300     // screenshot: ~305 of 1244
    static let trailingMargin: CGFloat = 16
    static let topMargin: CGFloat = 16
    static let gutter: CGFloat = columnWidth + trailingMargin * 2   // chat's reserved right inset
    static let cardSpacing: CGFloat = 24   // clears overlay shadow reach (y+radius = 6+14 = 20pt) with margin
    /// Horizontal reach of `.orbitOverlayChrome` (matches `OrbitShape.overlayShadowRadius`).
    /// Used by `SidecardColumn` overflow padding so shadows aren't hard-clipped by `ScrollView`.
    static let shadowHorizontalInset: CGFloat = 14
}
