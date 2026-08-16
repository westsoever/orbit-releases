import SwiftUI

/// Layout constants for the floating sidebane overlay and the chat gutter it reserves.
enum SidebaneMetrics {
    static let columnWidth: CGFloat = 220
    static let leadingMargin: CGFloat = 16
    static let topMargin: CGFloat = 16
    static let bottomMargin: CGFloat = 16
    static let gutter: CGFloat = columnWidth + leadingMargin * 2
    static let rowSpacing: CGFloat = 8
    static let groupSpacing: CGFloat = 20
    /// Padding inside `SidebaneShell.header`, which reserves a trailing slot (its `Spacer`)
    /// for the hide control.
    static let headerPadding: CGFloat = 12
    /// `OrbitIconButton` at `.md`, icon-only — `OrbitFlatButtonStyle.iconOnlyDimension`.
    static let toggleDimension: CGFloat = 28
    /// Leading offset that parks the hide control in the open pane's header trailing slot.
    /// Without this the button sits at `leadingMargin` — directly on top of the wordmark.
    static let toggleLeadingOpen: CGFloat = leadingMargin + columnWidth - headerPadding - toggleDimension
    /// Centres the 28pt control on the header's text row (`headerPadding` + half the
    /// callout line box) instead of hanging from the card's top edge.
    static let toggleTopInset: CGFloat = 6
    /// Trailing slot for menu chevron (History/Search) — mirrored as empty space on plain rows.
    static let menuAffordanceWidth: CGFloat = 14
}
