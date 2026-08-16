import SwiftUI

/// Plan 33 Phase 3 — the one sequential colour ramp used by this surface.
///
/// **Sequential, single hue (the app accent), light → dark. These opacities are computed,
/// not eyeballed — do not "tidy" them.** An earlier terracotta-era draft used 0.35 for level 1;
/// its empty → level-1 step was only 1.15:1, i.e. invisible.
///
/// Re-verified for the ink-blue accent (plan 54 §0.4/Phase 4, 2026-08-16): carrying the
/// terracotta-era opacities (0.45 / 0.70 / 1.0) forward unchanged produced a dark-mode
/// empty → level-1 step of only **1.09:1** — worse than the already-rejected 1.15:1 above —
/// because ink-blue's dark accent (`#3C5680`, relative luminance 0.092) sits far closer to the
/// dark canvas (`#10141C`, relative luminance 0.007) than terracotta's did; even the accent at
/// full opacity only reaches 1.89:1 against the dark track, so no opacity choice reproduces
/// terracotta's old dark-mode separation here. **The opacities were changed to 0.60 / 0.80 /
/// 1.0** — chosen to evenly log-space the three steps across that smaller luminance budget
/// instead of front-loading too little contrast into level 1 — checked by compositing each step
/// over the real canvas tokens:
///
/// - light canvas `#E5EAF2`: empty `#CED3DA` → `#76849E` → `#516282` → `#2C4066`
///   — consecutive steps 2.51 / 1.63 / 1.68 : 1, monotonically darkening.
/// - dark canvas `#10141C`: empty `#282C33` → `#2A3C58` → `#33496C` → `#3C5680`
///   — consecutive steps 1.26 / 1.23 / 1.23 : 1, monotonically lightening.
///
/// Dark-mode steps are still tighter than terracotta's old 1.63 / 1.62 / 1.70:1 — that
/// compression is intrinsic to how close the ink-blue accent's luminance sits to the dark
/// canvas, not a tuning miss — but every step now clears the 1.15:1 "not invisible" bar with
/// room, evenly, instead of collapsing at level 1 the way the unmodified terracotta-era
/// opacities did. Light-mode steps are comparable to, or better separated than, terracotta's.
///
/// Because every level shares one hue, **identity must never be carried by colour alone**:
/// anything using this ramp for categories owes the user a text legend or a direct label.
enum UsageRamp {
    static let level1Opacity: Double = 0.60
    static let level2Opacity: Double = 0.80
    static let level3Opacity: Double = 1.0

    /// `level` 0 is "no data" and resolves to the shared track token; 1…3 walk the ramp.
    static func color(level: Int, colorScheme: ColorScheme) -> Color {
        level <= 0 ? Color.orbitTrack(for: colorScheme) : accent(level: level, colorScheme: colorScheme)
    }

    /// Levels 1…3 only. The accent token is per-scheme (plan 54, ink-blue revision), so the ramp
    /// needs the scheme threaded through — re-verified against the real ink-blue accent and
    /// canvas tokens per plan 54 §0.4/Phase 4; see the doc comment above for the current figures.
    static func accent(level: Int, colorScheme: ColorScheme) -> Color {
        switch level {
        case 1: return Color.orbitAccent(for: colorScheme).opacity(level1Opacity)
        case 2: return Color.orbitAccent(for: colorScheme).opacity(level2Opacity)
        default: return Color.orbitAccent(for: colorScheme).opacity(level3Opacity)
        }
    }
}

/// Plan 33 Phase 3 (3) — a single stacked proportion bar plus its mandatory text legend.
///
/// Dumb view: segments arrive as values. Renders one `Color.orbitTrack(for:)` bar when the
/// total is 0, so an empty database still shows the shape of the thing.
struct UsageCompositionBar: View {
    /// One slice. `color == nil` means "unknown / no data" and resolves to the track token
    /// against the current colour scheme (a pure factory cannot know the scheme, so the
    /// resolution happens here rather than at the call site).
    struct Segment: Identifiable {
        let label: String
        let value: Int
        let color: Color?

        init(label: String, value: Int, color: Color? = nil) {
            self.label = label
            self.value = value
            self.color = color
        }

        var id: String { label }
    }

    let segments: [Segment]
    var barHeight: CGFloat = 16

    @Environment(\.colorScheme) private var colorScheme

    private var total: Int { segments.reduce(0) { $0 + max(0, $1.value) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                if total == 0 {
                    // Zero total: one visible track, never a NaN-width fill.
                    RoundedRectangle(cornerRadius: OrbitShape.radiusControl)
                        .fill(Color.orbitTrack(for: colorScheme))
                } else {
                    HStack(spacing: 2) {
                        ForEach(segments) { segment in
                            RoundedRectangle(cornerRadius: OrbitShape.radiusControl)
                                .fill(segment.color ?? Color.orbitTrack(for: colorScheme))
                                .frame(width: width(for: segment, in: geo.size.width))
                        }
                    }
                }
            }
            .frame(height: barHeight)

            legend
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    /// Identity is carried by text, not by hue: the segments deliberately share one hue
    /// (they are an ordinal quality ramp), so this legend is not optional decoration.
    private var legend: some View {
        FlowLayout(spacing: 10) {
            ForEach(segments) { segment in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(segment.color ?? Color.orbitTrack(for: colorScheme))
                        .frame(width: 8, height: 8)
                    Text("\(segment.label) \(percentText(for: segment))")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                }
            }
        }
    }

    /// `max(1, total)` is the divide-by-zero guard; the `total == 0` branch above means it
    /// is never actually reached with an empty bar, and it keeps the maths total-safe anyway.
    private func width(for segment: Segment, in available: CGFloat) -> CGFloat {
        let spacing = 2.0 * CGFloat(max(0, segments.count - 1))
        let usable = max(0, available - spacing)
        let share = Double(max(0, segment.value)) / Double(max(1, total))
        return usable * CGFloat(share)
    }

    private func percentText(for segment: Segment) -> String {
        let share = Double(max(0, segment.value)) / Double(max(1, total))
        return "\(Int((share * 100).rounded()))%"
    }

    private var accessibilitySummary: String {
        guard total > 0 else { return "Capture composition: no data yet" }
        let parts = segments.map { "\($0.label) \(percentText(for: $0))" }
        return "Capture composition: " + parts.joined(separator: ", ")
    }
}

// MARK: - Capture-method segments

extension UsageCompositionBar {
    /// Capture tier is **ordinal quality**, not a category, so it is encoded with the
    /// magnitude ramp above (richest → poorest), never with the status palette:
    /// `orbitScoreRed/Amber/Lime/Emerald` mean "how good is your score" app-wide and must
    /// not be repurposed as series colours. Unknown methods fall back to the track token.
    static func captureMethodSegments(_ tiers: [CaptureTierSlice], colorScheme: ColorScheme) -> [Segment] {
        let order = ["ax_enhanced", "ax", "metadata_only"]
        let levels = ["ax_enhanced": 3, "ax": 2, "metadata_only": 1]
        let names = ["ax_enhanced": "enhanced", "ax": "ax", "metadata_only": "metadata"]

        let known = order.compactMap { method -> Segment? in
            guard let tier = tiers.first(where: { $0.method == method }) else { return nil }
            return Segment(
                label: names[method] ?? method,
                value: tier.events,
                color: UsageRamp.accent(level: levels[method] ?? 1, colorScheme: colorScheme)
            )
        }
        let others = tiers
            .filter { levels[$0.method] == nil }
            .map { Segment(label: $0.method.isEmpty ? "unknown" : $0.method, value: $0.events, color: nil) }

        return known + others
    }
}

// MARK: - Previews

// (i) real §0.4 figures: ax_enhanced 587 · metadata_only 499 · ax 343.
struct UsageCompositionBarPreviewA: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading, spacing: 16) {
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
            // With an unrecognised method, which must fall back to the track token.
            UsageCompositionBar(
                segments: UsageCompositionBar.captureMethodSegments(
                    [
                        CaptureTierSlice(method: "ax_enhanced", events: 587),
                        CaptureTierSlice(method: "ax", events: 343),
                        CaptureTierSlice(method: "future_tier", events: 40),
                    ],
                    colorScheme: .light
                )
            )
        }
        .padding(16)
        .frame(width: 300)
        .previewDisplayName("Composition — real figures")
    }
}

// (ii) all-zero / empty.
struct UsageCompositionBarPreviewB: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading, spacing: 16) {
            UsageCompositionBar(segments: UsageCompositionBar.captureMethodSegments([], colorScheme: .light))
            UsageCompositionBar(
                segments: UsageCompositionBar.captureMethodSegments(
                    [
                        CaptureTierSlice(method: "ax_enhanced", events: 0),
                        CaptureTierSlice(method: "ax", events: 0),
                        CaptureTierSlice(method: "metadata_only", events: 0),
                    ],
                    colorScheme: .light
                )
            )
        }
        .padding(16)
        .frame(width: 300)
        .previewDisplayName("Composition — zero")
    }
}
