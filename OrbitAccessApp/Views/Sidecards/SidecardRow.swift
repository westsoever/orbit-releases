import SwiftUI

/// A flat inner row for content living inside a `SidecardShell` — the padding from
/// `OrbitCard`, without the background fill or hairline border, so rows don't render
/// as a card-within-a-card.
///
/// `accent` draws an optional 3pt leading bar and defaults to `.clear`, which omits the
/// bar entirely and lets content sit flush. Since plan 28 no call site passes a colour:
/// agent identity is carried by `AgentTypeBadge`, not by a bar. The parameter is kept for
/// rows that need a genuine colour rail; do not pass a near-invisible tint through it —
/// that reserves 3pt of width and offsets the content while rendering as nothing.
struct SidecardRow<Content: View>: View {
    var accent: Color = .clear
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            if accent != .clear {
                accent
                    .frame(width: 3)
                    .clipShape(RoundedRectangle(cornerRadius: 1.5))
            }
            content()
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
