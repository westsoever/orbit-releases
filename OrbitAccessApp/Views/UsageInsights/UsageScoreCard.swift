import SwiftUI

/// Plan 33 Phase 3 (2) — the productivity score, moved out of the sidecard column.
///
/// Reuses `ProductivityScoreGauge` **unchanged** and shows the four `ScoreInputs` beneath it.
/// The score itself is never recomputed here: `ProductivityScore` owns the 0.35 / 0.25 / 0.20 /
/// 0.20 weights (`Models/ProductivityScore.swift`), and this view only reads `score.value`
/// and `score.inputs`. The weights appear in `.help(…)` for reference, nothing more.
///
/// **Period label (Plan 33 §0.7.5).** `computeScoreInputs()` scopes its inputs to *UTC* days
/// while every other card on this sheet counts *local* days, so this card says "Today (UTC)"
/// out loud rather than letting the user assume it shares "today" with its neighbours.
struct UsageScoreCard: View {
    let score: ProductivityScore

    @Environment(\.colorScheme) private var colorScheme
    /// Animated reveal, same idiom as `ProductivityScoreGauge`: 0 → 1 scales the four fills.
    @State private var reveal: Double = 0

    private struct InputRow: Identifiable {
        let label: String
        let value: Double
        let weight: Int
        var id: String { label }
    }

    private var rows: [InputRow] {
        [
            InputRow(label: "tasks", value: score.inputs.taskCompletion, weight: 35),
            InputRow(label: "focus", value: score.inputs.focusDepth, weight: 25),
            InputRow(label: "richness", value: score.inputs.contextRichness, weight: 20),
            InputRow(label: "consistency", value: score.inputs.captureConsistency, weight: 20),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProductivityScoreGauge(score: score)

            Text("Today (UTC)")
                .font(.caption2)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                .frame(maxWidth: .infinity, alignment: .center)

            OrbitHairlineDivider(horizontalPadding: 0)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows) { row in
                    inputRow(row)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .orbitCardChrome(cornerRadius: OrbitShape.radiusSidecard, colorScheme: colorScheme)
        .onAppear {
            withAnimation(OrbitMotion.scoreReveal) { reveal = 1 }
        }
        .onChange(of: score.value) { _, _ in
            reveal = 0
            withAnimation(OrbitMotion.scoreReveal) { reveal = 1 }
        }
    }

    private func inputRow(_ row: InputRow) -> some View {
        HStack(spacing: 8) {
            Text(row.label)
                .font(.caption)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                .frame(width: 74, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: OrbitShape.radiusControl)
                        .fill(Color.orbitTrack(for: colorScheme))
                    RoundedRectangle(cornerRadius: OrbitShape.radiusControl)
                        .fill(Color.orbitAccent(for: colorScheme))
                        .frame(width: geo.size.width * CGFloat(fraction(row.value) * reveal))
                }
            }
            .frame(height: 6)

            Text("\(percent(row.value))%")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.primary)
                .frame(width: 38, alignment: .trailing)
        }
        .help("\(row.label) — weight \(row.weight)% of the score")
    }

    /// Clamped, never divided: `ScoreInputs` are already 0…1, so a zero input yields a
    /// zero-width fill over a full-width track. No division means no NaN.
    private func fraction(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private func percent(_ value: Double) -> Int {
        Int((fraction(value) * 100).rounded())
    }
}

// MARK: - Previews

// (i) real §0.4 figures: the mock's 40 / 65 / 100 / 88 inputs.
struct UsageScoreCardPreviewA: PreviewProvider {
    static var previews: some View {
        UsageScoreCard(
            score: ProductivityScore(
                inputs: ScoreInputs(
                    taskCompletion: 0.40,
                    focusDepth: 0.65,
                    contextRichness: 1.0,
                    captureConsistency: 0.88
                )
            )
        )
        .padding(16)
        .frame(width: 260)
        .previewDisplayName("Score card — real figures")
    }
}

// (ii) all-zero: gauge at 0.0, four zero-width fills over four visible tracks.
struct UsageScoreCardPreviewB: PreviewProvider {
    static var previews: some View {
        UsageScoreCard(
            score: ProductivityScore(
                inputs: ScoreInputs(
                    taskCompletion: 0,
                    focusDepth: 0,
                    contextRichness: 0,
                    captureConsistency: 0
                )
            )
        )
        .padding(16)
        .frame(width: 260)
        .previewDisplayName("Score card — zero")
    }
}
