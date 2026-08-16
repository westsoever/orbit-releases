import SwiftUI

/// "Detection" tab of the ⌘, Settings scene (Plan 17 Phase 6.4). Exposes
/// `detect_enabled` / `detect_daily_cap` in `~/.orbit/policy.json`, read by the
/// idle-triggered proactive task detector in `orbit/capture/daemon.py` (Plan 17
/// Phase 5.4). Off by default — CLAUDE.md's approval-fatigue budget is a
/// prerequisite for turning this on, not a polish item.
struct DetectionSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme

    @State private var settings = CapturePolicyStorage.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Detection")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "PROACTIVE TASK DETECTION")
                OrbitCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Detect tasks from your captured context", isOn: $settings.detectEnabled)
                            .onChange(of: settings.detectEnabled) { _, _ in persist() }
                        Text(
                            "When enabled, orbit periodically scans recent context for tasks worth " +
                            "surfacing for your approval. This is deliberately rationed to a small " +
                            "number of high-quality approval requests per day — 2–5 — rather than " +
                            "constant interruptions."
                        )
                        .font(.caption2)
                        .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "DAILY APPROVAL BUDGET")
                OrbitCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Stepper(
                            "Up to \(settings.detectDailyCap) approval requests per day",
                            value: $settings.detectDailyCap,
                            in: 1...20,
                            step: 1
                        )
                        .onChange(of: settings.detectDailyCap) { _, _ in persist() }
                        .disabled(!settings.detectEnabled)
                        Text("Keep this near the 2–5/day budget — a higher cap risks approval fatigue.")
                            .font(.caption2)
                            .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: 420, alignment: .leading)
        .background(Color.orbitCanvas(for: colorScheme))
    }

    private func persist() {
        CapturePolicyStorage.save(settings)
    }
}
