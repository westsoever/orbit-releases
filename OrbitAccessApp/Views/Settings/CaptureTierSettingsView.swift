import SwiftUI

/// "Capture" tab of the ⌘, Settings scene (Plan 17 Phase 6.4). Exposes the capture-tier
/// fields of `~/.orbit/policy.json` that are actually read by the Python daemon —
/// `tier_ocr`, `tier_fsevents`, `retention_days`. `tier_ax_text`/`tier_browser_ext` are
/// intentionally absent (parsed but never read; see `CapturePolicyStorage`), and
/// `capture_paused`/`excluded_bundles` are intentionally absent (already covered by
/// `PrivacyControlsView`).
struct CaptureTierSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme

    @State private var settings = CapturePolicyStorage.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Capture")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "OCR FALLBACK")
                OrbitCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Enable OCR fallback (tier_ocr)", isOn: $settings.tierOcr)
                            .onChange(of: settings.tierOcr) { _, _ in persist() }
                        Text("Falls back to on-screen text recognition when Accessibility capture fails for an app.")
                            .font(.caption2)
                            .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                        if settings.tierOcr {
                            Text("Also grant Screen Recording to Terminal/Python (see orbit/capture/PERMISSIONS.md)")
                                .font(.caption2)
                                .foregroundStyle(Color.orbitScoreAmber)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "FILE ACTIVITY")
                OrbitCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Watch project folders (tier_fsevents)", isOn: $settings.tierFsevents)
                            .onChange(of: settings.tierFsevents) { _, _ in persist() }
                        Text("Records file create/modify/delete activity under your configured watch roots.")
                            .font(.caption2)
                            .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "RETENTION")
                OrbitCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Stepper(
                            "Keep captured events for \(settings.retentionDays) days",
                            value: $settings.retentionDays,
                            in: 1...365,
                            step: 1
                        )
                        .onChange(of: settings.retentionDays) { _, _ in persist() }
                        Text("Older events are purged on daemon startup with --purge-retention, or via orbit privacy purge.")
                            .font(.caption2)
                            .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "ANALYTICS")
                OrbitCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Share usage analytics & crash reports (telemetry_enabled)", isOn: $settings.telemetryEnabled)
                            .onChange(of: settings.telemetryEnabled) { _, enabled in
                                persist()
                                TelemetryService.shared.setEnabled(enabled, policy: settings)
                            }
                        Text("Sends structural usage events and crash reports (Sentry + PostHog) — never window text, URLs, search queries, chat messages, or task content. On by default.")
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
