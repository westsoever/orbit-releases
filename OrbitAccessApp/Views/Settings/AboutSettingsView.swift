import SwiftUI

/// Surfaces the legal documents drafted to close launch-blockers #4 (LICENSE), #5 (Privacy
/// Policy), and #6 (Terms of Service) — see docs/gdpr/LEGAL_REVIEW_CHECKLIST.md.
///
/// Links point at `orbit-releases`, which still holds the *published* copies. The original
/// reason was that the source repo was private; it is public as of 2026-08-16, so that reason
/// is gone — but the destination is deliberately unchanged. `docs/gdpr/` in the source repo
/// holds working drafts that are explicitly "not yet finalized by counsel" and whose header
/// still reads `**Last updated:** [DATE — set on publication]`. Pointing users at those would
/// show them a placeholder instead of the version approved for publication.
///
/// **Known drift, deliberately not fixed here:** the published policy (2026-08-13, 159 lines)
/// predates the accounts and profile questionnaire added in plan 53 and describes neither.
/// That is not yet a live gap — cloud sign-in is off unless `ORBIT_CLOUD_AUTH_ENABLED` is set,
/// which it never is for a double-clicked build, so a shipped app cannot collect either — but
/// the published copy MUST be re-synced before cloud auth is enabled for anyone. Tracked as
/// B15 in plans/BACKLOG.md.
struct AboutSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme

    private static let releasesRepo = "https://github.com/westsoever/orbit-releases"

    private var links: [(title: String, url: URL)] {
        [
            ("License", URL(string: "\(Self.releasesRepo)/blob/main/LICENSE")!),
            ("Privacy Policy", URL(string: "\(Self.releasesRepo)/blob/main/docs/PRIVACY_POLICY.md")!),
            ("Terms of Service", URL(string: "\(Self.releasesRepo)/blob/main/docs/TERMS_OF_SERVICE.md")!),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("About")
                .font(.headline)

            Text(appVersionLine)
                .font(.callout)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))

            VStack(alignment: .leading, spacing: 6) {
                ForEach(links, id: \.title) { link in
                    Button(link.title) {
                        NSWorkspace.shared.open(link.url)
                    }
                    .buttonStyle(.link)
                }
            }

            Text("These documents are drafts pending legal review and may not yet reflect a counsel-approved final version.")
                .font(.caption)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))

            Text("Orbit sends structural usage analytics and crash reports by default (see Privacy Policy above) — disable this anytime in Settings > Capture > Analytics.")
                .font(.caption)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
        }
        .padding()
        .frame(maxWidth: 360, alignment: .leading)
        .background(Color.orbitCanvas(for: colorScheme))
    }

    private var appVersionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.1"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "Orbit \(version) (\($0))" } ?? "Orbit \(version)"
    }
}
