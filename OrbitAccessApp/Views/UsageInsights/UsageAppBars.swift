import SwiftUI

/// Plan 33 Phase 3 (4) — one horizontal bar per app.
///
/// Single accent hue over the shared track, and every row is **direct-labelled with the app
/// name**, so there is nothing for a legend to disambiguate.
///
/// Percentages are shares of the **sum of the rows shown**, not of all-time capture — the
/// caption says so, because "65%" is otherwise ambiguous (Plan 33 Phase 3 item 4).
struct UsageAppBars: View {
    let apps: [AppUsage]

    @Environment(\.colorScheme) private var colorScheme
    @State private var reveal: Double = 0

    private var totalAtoms: Int { apps.reduce(0) { $0 + max(0, $1.atoms) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if apps.isEmpty {
                Text("No app activity in the last 30 days")
                    .font(.caption)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(apps) { app in
                        row(app)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Atoms captured per app, last 30 days")

                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            withAnimation(OrbitMotion.scoreReveal) { reveal = 1 }
        }
        .onChange(of: totalAtoms) { _, _ in
            reveal = 0
            withAnimation(OrbitMotion.scoreReveal) { reveal = 1 }
        }
    }

    private var caption: String {
        "Share of the \(apps.count) app\(apps.count == 1 ? "" : "s") shown, by atoms captured — not of all-time capture."
    }

    private func row(_ app: AppUsage) -> some View {
        HStack(spacing: 8) {
            Text("\(percent(app.atoms))%")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.primary)
                .frame(width: 44, alignment: .trailing)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: OrbitShape.radiusControl)
                        .fill(Color.orbitTrack(for: colorScheme))
                    RoundedRectangle(cornerRadius: OrbitShape.radiusControl)
                        .fill(Color.orbitAccent(for: colorScheme))
                        .frame(width: geo.size.width * CGFloat(share(app.atoms) * reveal))
                }
            }
            .frame(height: 8)

            Text(app.appName.isEmpty ? app.bundleId : app.appName)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 88, alignment: .leading)
        }
        .help("\(app.atoms.formatted()) atoms")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(app.appName.isEmpty ? app.bundleId : app.appName): \(percent(app.atoms)) percent, \(app.atoms.formatted()) atoms"
        )
    }

    /// `max(1, totalAtoms)` is the divide-by-zero guard: with every row at zero atoms the
    /// share is 0, so each row draws a full-width track and a zero-width fill — never NaN.
    private func share(_ atoms: Int) -> Double {
        Double(max(0, atoms)) / Double(max(1, totalAtoms))
    }

    private func percent(_ atoms: Int) -> Int {
        Int((share(atoms) * 100).rounded())
    }
}

// MARK: - Previews

// (i) real §0.4 figures: Cursor 46,535 · Code 9,727 · Dia 8,213 · System Settings 764.
struct UsageAppBarsPreviewA: PreviewProvider {
    static var previews: some View {
        UsageAppBars(
            apps: [
                AppUsage(bundleId: "com.todesktop.230313mzl4w4u92", appName: "Cursor", events: 620, atoms: 46_535),
                AppUsage(bundleId: "com.microsoft.VSCode", appName: "Code", events: 210, atoms: 9_727),
                AppUsage(bundleId: "company.thebrowser.dia", appName: "Dia", events: 180, atoms: 8_213),
                AppUsage(bundleId: "com.apple.systempreferences", appName: "System Settings", events: 22, atoms: 764),
                AppUsage(bundleId: "com.vivaldi.Vivaldi", appName: "Vivaldi", events: 9, atoms: 151),
            ]
        )
        .padding(16)
        .frame(width: 380)
        .previewDisplayName("App bars — real figures")
    }
}

// (ii) empty, plus the all-zero case that would divide by zero if unguarded.
struct UsageAppBarsPreviewB: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading, spacing: 16) {
            UsageAppBars(apps: [])
            UsageAppBars(
                apps: [
                    AppUsage(bundleId: "com.apple.Terminal", appName: "Terminal", events: 0, atoms: 0),
                    AppUsage(bundleId: "com.apple.Safari", appName: "Safari", events: 0, atoms: 0),
                ]
            )
        }
        .padding(16)
        .frame(width: 380)
        .previewDisplayName("App bars — zero")
    }
}
