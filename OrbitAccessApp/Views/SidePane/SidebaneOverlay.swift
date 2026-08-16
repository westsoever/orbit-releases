import SwiftUI

/// Floating left-aligned container for the sidebane rail. No background or border
/// on the overlay itself — only the card inside `SidebaneShell` has a surface.
struct SidebaneOverlay: View {
    var body: some View {
        SidebaneShell {
            SidebaneView()
        }
        .frame(width: SidebaneMetrics.columnWidth)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
