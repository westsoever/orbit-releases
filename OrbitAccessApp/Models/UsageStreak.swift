import Foundation

// Plan 33 Phase 1 — pure tallies.
//
// Nothing in this file reads the database, and nothing calls `Date()`: `today` / `now`
// are always parameters, which is what keeps both of these checkable by hand.

/// Capture-streak arithmetic over the set of local days that have activity.
enum UsageStreak {
    /// Length of the streak that includes `today`.
    ///
    /// Counts back one day at a time from `today`. If `today` has no activity yet the
    /// count is anchored on yesterday instead, so the streak does not read 0 before the
    /// first capture of the morning. Returns 0 when neither day is active.
    ///
    /// All days are normalised with `calendar.startOfDay(for:)` before comparison.
    static func current(days: Set<Date>, today: Date, calendar: Calendar) -> Int {
        let active = Set(days.map { calendar.startOfDay(for: $0) })
        guard !active.isEmpty else { return 0 }

        let todayStart = calendar.startOfDay(for: today)
        let anchor: Date
        if active.contains(todayStart) {
            anchor = todayStart
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: todayStart),
                  active.contains(yesterday) {
            anchor = yesterday
        } else {
            return 0
        }

        var count = 0
        var cursor = anchor
        while active.contains(cursor) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }

    /// Longest run of consecutive active days anywhere in `days`.
    ///
    /// `calendar` is defaulted so the signature can be called as `longest(days:)`; it is a
    /// parameter rather than a captured `Calendar.current` because day adjacency is not a
    /// fixed 86,400 s (DST transitions), so real calendar arithmetic is required.
    static func longest(days: Set<Date>, calendar: Calendar = .current) -> Int {
        let sorted = Set(days.map { calendar.startOfDay(for: $0) }).sorted()
        guard !sorted.isEmpty else { return 0 }

        var best = 1
        var run = 1
        for index in 1..<sorted.count {
            if let next = calendar.date(byAdding: .day, value: 1, to: sorted[index - 1]),
               calendar.isDate(next, inSameDayAs: sorted[index]) {
                run += 1
            } else {
                run = 1
            }
            best = max(best, run)
        }
        return best
    }
}

// MARK: - Routine tally

extension RoutineTally {
    /// Counts routines by delegating entirely to the existing `RoutineSchedule` predicates.
    ///
    /// No new schedule maths lives here on purpose (Plan 33 anti-pattern 10):
    /// `RoutineSchedule.isActive` means *inside today's window*, never *running*.
    static func from(routines: [RoutineBlock], now: Date, calendar: Calendar) -> RoutineTally {
        RoutineTally(
            total: routines.count,
            scheduledToday: routines.filter {
                RoutineSchedule.isScheduledToday($0, now: now, calendar: calendar)
            }.count,
            inWindowNow: routines.filter {
                RoutineSchedule.isActive($0, now: now, calendar: calendar)
            }.count,
            completedToday: routines.filter {
                RoutineSchedule.isCompletedToday($0, now: now, calendar: calendar)
            }.count
        )
    }
}
