import SwiftUI

/// Plan 33 Phase 3 (5), revised by Plan 41-B — the GitHub-style capture grid: 7 rows, Sunday
/// at the top, **no weekday labels down the left** (the date lives in the tooltip and in the
/// accessibility label instead, so dropping the column loses no information).
///
/// The column count is **derived from the available width** so the grid fills its card rather
/// than leaving dead space at a hard-coded count — see `columns`. Width is measured via a
/// `GeometryReader` in the `.background`, which lets the reader report the real width the
/// card gives this view without forcing the whole subtree (including the variable-height
/// footnote) to live inside a `GeometryReader`'s greedy height. The result is clamped to
/// `maxColumns` (26 weeks / 182 days, open decision 4 in the parallel-execution plan), which is
/// also the data horizon requested from the store (`UsageInsightsStore.gridDays`).
///
/// Intensity comes from **events per day**, not atoms: per-day atom counts cost ~1.3 s at
/// 90-day scale, so `DayActivity` carries events only (Plan 33 §0.7.2).
///
/// Dumb view: `today` and `calendar` are parameters, never `Date()` / implicit current, so a
/// preview renders the same squares every time.
struct UsageStreakGrid: View {
    let days: [DayActivity]
    let today: Date
    var calendar: Calendar = .current

    private static let rows = 7
    private static let cellSize: CGFloat = 11
    private static let cellSpacing: CGFloat = 3
    /// 26 weeks / 182 days — the clamp from open decision 4. Must not exceed
    /// `UsageInsightsStore.gridDays / 7`.
    private static let maxColumns = 26

    /// Columns that fit `width`, at least 1, never more than `maxColumns`.
    private static func columnCount(for width: CGFloat) -> Int {
        let fit = Int((width + cellSpacing) / (cellSize + cellSpacing))
        return min(maxColumns, max(1, fit))
    }

    @Environment(\.colorScheme) private var colorScheme
    /// Measured by the `.background` `GeometryReader` below; drives `columns`. Starts at 0
    /// (→ a single column) until the first layout pass reports the real width.
    @State private var availableWidth: CGFloat = 0

    private var columns: Int { Self.columnCount(for: availableWidth) }

    /// Events keyed by local start-of-day.
    private var eventsByDay: [Date: Int] {
        Dictionary(
            days.map { (calendar.startOfDay(for: $0.day), max(0, $0.events)) },
            uniquingKeysWith: +
        )
    }

    private var maxEvents: Int {
        days.map { max(0, $0.events) }.max() ?? 0
    }

    /// Sunday of the week containing `today`, i.e. the first cell of the last column.
    private var lastColumnStart: Date {
        let start = calendar.startOfDay(for: today)
        let weekday = calendar.component(.weekday, from: start)  // 1 = Sunday, Gregorian
        return calendar.date(byAdding: .day, value: -(weekday - 1), to: start) ?? start
    }

    private func columnStart(_ column: Int) -> Date {
        calendar.date(
            byAdding: .day,
            value: -7 * (columns - 1 - column),
            to: lastColumnStart
        ) ?? lastColumnStart
    }

    private func cellDate(column: Int, row: Int) -> Date {
        calendar.date(byAdding: .day, value: row, to: columnStart(column)) ?? columnStart(column)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: Self.cellSpacing) {
                ForEach(0..<columns, id: \.self) { column in
                    VStack(alignment: .leading, spacing: Self.cellSpacing) {
                        monthLabel(column)
                        ForEach(0..<Self.rows, id: \.self) { row in
                            cell(column: column, row: row)
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(
                "Capture activity, last \(columns) week\(columns == 1 ? "" : "s")"
            )

            legend

            Text(footnote)
                .font(.caption2)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { availableWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, newValue in
                        availableWidth = newValue
                    }
            }
        )
    }

    @ViewBuilder
    private func monthLabel(_ column: Int) -> some View {
        // A column is labelled when its month differs from the previous column's; the
        // leftmost column is always labelled so the earliest month is named.
        let start = columnStart(column)
        let show: Bool = column == 0
            || calendar.component(.month, from: start)
                != calendar.component(.month, from: columnStart(column - 1))

        Text(show ? start.formatted(.dateTime.month(.abbreviated)) : "")
            .font(.caption2)
            .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
            .fixedSize()
            .frame(width: Self.cellSize, height: 11, alignment: .leading)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func cell(column: Int, row: Int) -> some View {
        let date = cellDate(column: column, row: row)
        let isFuture = date > calendar.startOfDay(for: today)
        let events = eventsByDay[date] ?? 0
        let dateText = date.formatted(date: .abbreviated, time: .omitted)

        if isFuture {
            // Days that have not happened yet are left blank rather than read as "0 events".
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.clear)
                .frame(width: Self.cellSize, height: Self.cellSize)
                .accessibilityHidden(true)
        } else {
            RoundedRectangle(cornerRadius: 2)
                .fill(UsageRamp.color(level: level(events), colorScheme: colorScheme))
                .frame(width: Self.cellSize, height: Self.cellSize)
                // `.help` is a pointer tooltip, not an accessibility label — both are needed.
                .help("\(dateText) — \(events.formatted()) events")
                .accessibilityElement()
                .accessibilityLabel("\(dateText) — \(events.formatted()) events")
        }
    }

    private var legend: some View {
        HStack(spacing: Self.cellSpacing) {
            Text("Less")
                .font(.caption2)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
            ForEach(0...3, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2)
                    .fill(UsageRamp.color(level: level, colorScheme: colorScheme))
                    .frame(width: Self.cellSize, height: Self.cellSize)
            }
            Text("More")
                .font(.caption2)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Legend: darker squares mean more events captured that day")
    }

    /// The rendered window is a **display width, not a data horizon** — retention purging is
    /// opt-in and off by default (Plan 33 §0.7.3), so the "older captures" line only appears
    /// when there really is history off the left edge. No base sentence names the window size
    /// any more (Plan 41-B): the grid now fills its card, so a fixed "last N weeks" claim would
    /// go stale the moment the card is resized.
    private var footnote: String {
        guard let earliest = days.map({ calendar.startOfDay(for: $0.day) }).min(),
              earliest < columnStart(0)
        else { return "" }
        return "Older captures are kept but not shown here."
    }

    /// Buckets of the non-zero maximum. `max(1, maxEvents)` is the divide-by-zero guard: an
    /// empty database gives every cell level 0, i.e. a visible track, and never NaN.
    private func level(_ events: Int) -> Int {
        guard events > 0 else { return 0 }
        let fraction = Double(events) / Double(max(1, maxEvents))
        if fraction <= 1.0 / 3.0 { return 1 }
        if fraction <= 2.0 / 3.0 { return 2 }
        return 3
    }
}

// MARK: - Previews

private func usageStreakPreviewDate(_ iso: String) -> Date {
    // Fixed dates so both previews are deterministic — no `Date()` anywhere in this file.
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = .current
    return formatter.date(from: iso) ?? Date(timeIntervalSince1970: 0)
}

// (i) real §0.4 figures: 5 active days — 20 / 166 / 56 / 421 / 766 events.
struct UsageStreakGridPreviewA: PreviewProvider {
    static var previews: some View {
        UsageStreakGrid(
            days: [
                DayActivity(day: usageStreakPreviewDate("2026-06-28"), events: 20),
                DayActivity(day: usageStreakPreviewDate("2026-06-29"), events: 166),
                DayActivity(day: usageStreakPreviewDate("2026-07-25"), events: 56),
                DayActivity(day: usageStreakPreviewDate("2026-07-26"), events: 421),
                DayActivity(day: usageStreakPreviewDate("2026-07-27"), events: 766),
            ],
            today: usageStreakPreviewDate("2026-07-28")
        )
        .padding(16)
        .frame(width: 300)
        .previewDisplayName("Streak grid — real figures, 300pt")
    }
}

// (ii) empty: no NaN, no crash on `maxEvents == 0`, and no columns divide-by-zero.
struct UsageStreakGridPreviewB: PreviewProvider {
    static var previews: some View {
        UsageStreakGrid(days: [], today: usageStreakPreviewDate("2026-07-28"))
            .padding(16)
            .frame(width: 300)
            .previewDisplayName("Streak grid — empty")
    }
}

// (iii) wide card: proves the grid fills width instead of stopping at 13 columns.
struct UsageStreakGridPreviewC: PreviewProvider {
    static var previews: some View {
        UsageStreakGrid(
            days: [
                DayActivity(day: usageStreakPreviewDate("2026-06-28"), events: 20),
                DayActivity(day: usageStreakPreviewDate("2026-07-27"), events: 766),
            ],
            today: usageStreakPreviewDate("2026-07-28")
        )
        .padding(16)
        .frame(width: 760)
        .previewDisplayName("Streak grid — wide card, 760pt")
    }
}
