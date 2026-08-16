import SwiftUI

/// Plan 33 Phase 3 (6) — the shared "label + count rows" card behind both the Tasks and the
/// Routines cards.
///
/// **Zero-valued rows still render**: "0 detected" is information, and hiding it would make an
/// empty database look like a missing feature.
struct UsageTallyCard: View {
    struct Row: Identifiable {
        let label: String
        let value: Int

        init(label: String, value: Int) {
            self.label = label
            self.value = value
        }

        var id: String { label }
    }

    let title: String
    let rows: [Row]
    let footnote: String?

    @Environment(\.colorScheme) private var colorScheme

    init(title: String, rows: [Row], footnote: String? = nil) {
        self.title = title
        self.rows = rows
        self.footnote = footnote
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: title)

            if rows.isEmpty {
                Text("Nothing to count yet")
                    .font(.caption)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                ForEach(rows) { row in
                    HStack(spacing: 8) {
                        Text(row.value.formatted())
                            .font(.callout.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                        Text(row.label)
                            .font(.caption)
                            .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(row.value) \(row.label)")
                }
            }

            if let footnote {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .orbitCardChrome(cornerRadius: OrbitShape.radiusSidecard, colorScheme: colorScheme)
    }
}

extension UsageTallyCard {
    /// The exact wording already shipped in `RoutineList.swift:25-27`. Routines have no
    /// scheduler, so no surface may imply one (Plan 33 anti-pattern 10) — reused verbatim
    /// rather than paraphrased, so the two cards cannot drift apart.
    static let routineDisclaimer =
        "Routines do not run on a schedule yet — use Prepare in chat, or Mark done today."
}

// MARK: - Previews

// (i) real §0.4 figures: task_log has 2 dispatched rows and nothing else; 4 routines.
struct UsageTallyCardPreviewA: PreviewProvider {
    static var previews: some View {
        HStack(alignment: .top, spacing: 16) {
            UsageTallyCard(
                title: "TASKS",
                rows: [
                    UsageTallyCard.Row(label: "detected", value: 0),
                    UsageTallyCard.Row(label: "approved", value: 2),
                    UsageTallyCard.Row(label: "skipped", value: 0),
                ]
            )
            UsageTallyCard(
                title: "ROUTINES",
                rows: [
                    UsageTallyCard.Row(label: "configured", value: 4),
                    UsageTallyCard.Row(label: "scheduled today", value: 3),
                    UsageTallyCard.Row(label: "in window now", value: 0),
                    UsageTallyCard.Row(label: "completed today", value: 0),
                ],
                footnote: UsageTallyCard.routineDisclaimer
            )
        }
        .padding(16)
        .frame(width: 460)
        .previewDisplayName("Tally cards — real figures")
    }
}

// (ii) all-zero, plus the no-rows case.
struct UsageTallyCardPreviewB: PreviewProvider {
    static var previews: some View {
        HStack(alignment: .top, spacing: 16) {
            UsageTallyCard(
                title: "TASKS",
                rows: [
                    UsageTallyCard.Row(label: "detected", value: 0),
                    UsageTallyCard.Row(label: "approved", value: 0),
                    UsageTallyCard.Row(label: "skipped", value: 0),
                ]
            )
            UsageTallyCard(
                title: "ROUTINES",
                rows: [],
                footnote: UsageTallyCard.routineDisclaimer
            )
        }
        .padding(16)
        .frame(width: 460)
        .previewDisplayName("Tally cards — zero")
    }
}
