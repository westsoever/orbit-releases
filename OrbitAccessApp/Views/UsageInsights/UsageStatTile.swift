import SwiftUI

/// Plan 33 Phase 3 (1) — the top-row tile shell: one big number, a tracked micro-label,
/// then whatever detail the caller supplies.
///
/// Dumb view: every input arrives as a `let`. No store, no `Date()`, no DB.
/// The tile never sets its own width — the sheet's rows own that (Phase 4).
struct UsageStatTile<Detail: View>: View {
    let value: String
    let label: String
    let footnote: String?
    private let detail: () -> Detail

    @Environment(\.colorScheme) private var colorScheme

    init(
        value: String,
        label: String,
        footnote: String? = nil,
        @ViewBuilder detail: @escaping () -> Detail
    ) {
        self.value = value
        self.label = label
        self.footnote = footnote
        self.detail = detail
    }

    /// True when there is anything below the divider worth drawing a divider for.
    private var hasBody: Bool {
        Detail.self != EmptyView.self || footnote != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.system(size: 32, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            SectionHeader(title: label)

            if hasBody {
                OrbitHairlineDivider(horizontalPadding: 0)
                    .padding(.bottom, 2)

                detail()

                if let footnote {
                    Text(footnote)
                        .font(.caption2)
                        .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .orbitCardChrome(cornerRadius: OrbitShape.radiusSidecard, colorScheme: colorScheme)
    }
}

extension UsageStatTile where Detail == EmptyView {
    init(value: String, label: String, footnote: String? = nil) {
        self.init(value: value, label: label, footnote: footnote) { EmptyView() }
    }
}

// MARK: - Previews

// (i) real §0.4 figures.
struct UsageStatTilePreviewA: PreviewProvider {
    static var previews: some View {
        HStack(alignment: .top, spacing: 16) {
            UsageStatTile(
                value: "3,820",
                label: "ATOMS PER HOUR",
                footnote: "38,198 atoms in 10 active hours today"
            )
            UsageStatTile(
                value: "71,278",
                label: "ATOMS CAPTURED",
                footnote: "≈ 585 pages of notes"
            ) {
                UsageCompositionBar(
                    segments: UsageCompositionBar.captureMethodSegments(
                        [
                            CaptureTierSlice(method: "ax_enhanced", events: 587),
                            CaptureTierSlice(method: "metadata_only", events: 499),
                            CaptureTierSlice(method: "ax", events: 343),
                        ],
                        colorScheme: .light
                    )
                )
            }
        }
        .padding(16)
        .frame(width: 520)
        .previewDisplayName("Stat tile — real figures")
    }
}

// (ii) all-zero / empty.
struct UsageStatTilePreviewB: PreviewProvider {
    static var previews: some View {
        HStack(alignment: .top, spacing: 16) {
            UsageStatTile(value: "0", label: "ATOMS PER HOUR", footnote: "Nothing captured yet today")
            UsageStatTile(value: "0", label: "ATOMS CAPTURED") {
                UsageCompositionBar(segments: UsageCompositionBar.captureMethodSegments([], colorScheme: .light))
            }
        }
        .padding(16)
        .frame(width: 520)
        .previewDisplayName("Stat tile — zero")
    }
}
