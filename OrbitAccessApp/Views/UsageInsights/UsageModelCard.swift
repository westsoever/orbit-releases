import SwiftUI

/// Plan 33 Phase 3 (7) — AI usage: the most-called model in the window, its success rate, and
/// how it compares with the configured model.
///
/// **The success rate is always shown beside call volume** (Plan 33 anti-pattern 11). The real
/// `llm_calls` table contains a model with 0 of 6 successful calls and a literal
/// `nonexistent-model-xyz:999`, so call volume alone must never be presented as "working".
struct UsageModelCard: View {
    /// Most-called model in the window; nil when there were no calls at all.
    let favourite: ModelUsage?
    let totalCalls: Int
    let okCalls: Int
    /// From `~/.orbit/.env` (`ORBIT_LOCAL_LLM_MODEL`), not from the daemon.
    let configuredModel: String?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let favourite {
                Text(favourite.model.isEmpty ? "unknown" : favourite.model)
                    .font(.callout.weight(.semibold))
                    .monospaced()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                SectionHeader(title: "FAVOURITE MODEL")

                OrbitHairlineDivider(horizontalPadding: 0)
                    .padding(.bottom, 2)

                detailLine("\(favourite.calls.formatted())/\(totalCalls.formatted()) calls · \(percent(favourite.successRate))% ok")
                detailLine("avg \(latencyText(favourite.averageLatencyMs)) per call")
                detailLine("\(okCalls.formatted())/\(totalCalls.formatted()) ok overall")
                detailLine(configuredLine)
            } else {
                SectionHeader(title: "AI USAGE")
                Text("No AI calls in the last 30 days.")
                    .font(.caption)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                if let configuredModel, !configuredModel.isEmpty {
                    detailLine("configured: \(configuredModel)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .orbitCardChrome(cornerRadius: OrbitShape.radiusSidecard, colorScheme: colorScheme)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AI usage, last 30 days")
    }

    private func detailLine(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var configuredLine: String {
        guard let configuredModel, !configuredModel.isEmpty else {
            return "no configured model found"
        }
        guard let favourite else { return "configured: \(configuredModel)" }
        return favourite.model == configuredModel
            ? "same as configured"
            : "differs from configured (\(configuredModel))"
    }

    /// 22,382 ms reads as "22.4 s" — seconds, one decimal (Plan 33 Phase 3 item 7).
    private func latencyText(_ milliseconds: Int) -> String {
        String(format: "%.1f s", Double(max(0, milliseconds)) / 1000.0)
    }

    /// `ModelUsage.successRate` is already guarded (`calls > 0 ? … : 0`) in Phase 1, so this
    /// only rounds. The overall rate below uses `max(1, totalCalls)` for the same reason.
    private func percent(_ rate: Double) -> Int {
        Int((min(max(rate, 0), 1) * 100).rounded())
    }
}

// MARK: - Previews

// (i) real §0.4 figures: qwen2.5:14b 28/28 ok, avg 22,382 ms; 60 calls / 52 ok overall.
struct UsageModelCardPreviewA: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading, spacing: 16) {
            UsageModelCard(
                favourite: ModelUsage(
                    model: "qwen2.5:14b",
                    provider: "local",
                    calls: 28,
                    okCalls: 28,
                    averageLatencyMs: 22_382
                ),
                totalCalls: 60,
                okCalls: 52,
                configuredModel: "qwen2.5:14b"
            )
            // The anti-pattern-11 case: high volume, zero successes, and a junk tag.
            UsageModelCard(
                favourite: ModelUsage(
                    model: "nonexistent-model-xyz:999",
                    provider: "local",
                    calls: 6,
                    okCalls: 0,
                    averageLatencyMs: 1_083
                ),
                totalCalls: 60,
                okCalls: 52,
                configuredModel: "qwen2.5:14b"
            )
        }
        .padding(16)
        .frame(width: 280)
        .previewDisplayName("Model card — real figures")
    }
}

// (ii) empty / all-zero: no calls at all, and a zero-call model row.
struct UsageModelCardPreviewB: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading, spacing: 16) {
            UsageModelCard(favourite: nil, totalCalls: 0, okCalls: 0, configuredModel: "qwen2.5:14b")
            UsageModelCard(favourite: nil, totalCalls: 0, okCalls: 0, configuredModel: nil)
            UsageModelCard(
                favourite: ModelUsage(
                    model: "",
                    provider: "unspecified",
                    calls: 0,
                    okCalls: 0,
                    averageLatencyMs: 0
                ),
                totalCalls: 0,
                okCalls: 0,
                configuredModel: nil
            )
        }
        .padding(16)
        .frame(width: 280)
        .previewDisplayName("Model card — empty")
    }
}
