import SwiftUI

/// Floating right-aligned container for the sidecard column. No background,
/// no border — only the individual cards inside `SidecardColumn` have surfaces.
struct SidecardOverlay: View {
    @Environment(AppViewModel.self) private var model

    private var isEditing: Bool { model.sidecardStore.isEditing }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SidecardHeader()
                .frame(width: SidecardMetrics.columnWidth, alignment: .leading)

            ScrollView {
                SidecardColumn()
            }
            .scrollIndicators(.hidden)
            // Per-card `.orbitOverlayChrome` shadows extend horizontally; ScrollView
            // clips to bounds by default. Shell rows use shadow overflow padding instead
            // of shrinking card width — see `SidecardColumn.cardRow`.
            .scrollClipDisabled()

            // Always reserve footer height — mounting/unmounting on isEditing
            // changes preferred size and triggers NSHostingView.updateAnimatedWindowSize abort.
            editFooter
                .frame(width: SidecardMetrics.columnWidth, alignment: .leading)
                .opacity(isEditing ? 1 : 0)
                .allowsHitTesting(isEditing)
                .accessibilityHidden(!isEditing)
        }
        // Explicit constant width (same shadow-safe pattern as SidecardColumn.cardRow).
        // Do not use `.fixedSize(horizontal: true)` — it advertises intrinsic size into
        // the window hosting view and aborts on macOS 26 when edit chrome appears.
        .frame(width: SidecardMetrics.columnWidth, alignment: .leading)
        .padding(.horizontal, SidecardMetrics.shadowHorizontalInset)
        .padding(.horizontal, -SidecardMetrics.shadowHorizontalInset)
    }

    private var editFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("Reset layout") {
                withAnimation(OrbitMotion.collapse) {
                    model.sidecardStore.resetToDefaults()
                }
            }
            .buttonStyle(OrbitFlatButtonStyle(variant: .ghost, size: .sm))
        }
        .padding(.top, 4)
    }
}
