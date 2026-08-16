import SwiftUI

struct ProductivityScoreGauge: View {
    let score: Double
    @Environment(\.colorScheme) private var colorScheme
    @State private var animatedScore: Double = 0

    init(score: Double) {
        self.score = score
    }

    init(score: ProductivityScore) {
        self.score = score.value
    }

    private var color: Color { Color.orbitScoreColor(for: score) }
    private var label: String { Color.orbitScoreLabel(for: score) }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Canvas { context, size in
                    drawGauge(context: context, size: size, progress: animatedScore / 10)
                }
                .frame(width: 120, height: 72)

                Text(String(format: "%.1f", animatedScore))
                    .font(.system(size: 32, weight: .bold, design: .default))
                    .foregroundStyle(color)
                    .offset(y: 8)
            }

            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(color)
                .kerning(-0.1)

            Text("Productivity Score")
                .font(.caption2)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .onAppear {
            withAnimation(OrbitMotion.scoreReveal) {
                animatedScore = score
            }
        }
        .onChange(of: score) { _, newScore in
            withAnimation(OrbitMotion.scoreReveal) {
                animatedScore = newScore
            }
        }
    }

    private func drawGauge(context: GraphicsContext, size: CGSize, progress: Double) {
        let center = CGPoint(x: size.width / 2, y: size.height - 4)
        let radius = min(size.width, size.height * 2) / 2 - 4
        let startAngle = Angle.degrees(180)
        let endAngle = Angle.degrees(0)

        var trackPath = Path()
        trackPath.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        context.stroke(trackPath, with: .color(Color.orbitTrack(for: colorScheme)), lineWidth: 8)

        let sweep = 180.0 * min(max(progress, 0), 1)
        var fillPath = Path()
        fillPath.addArc(
            center: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: Angle.degrees(180 - sweep),
            clockwise: false
        )
        context.stroke(fillPath, with: .color(color), style: StrokeStyle(lineWidth: 8, lineCap: .round))
    }
}
