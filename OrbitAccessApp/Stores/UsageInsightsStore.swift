import Foundation
import Observation

// Plan 33 Phase 2 — the Usage Insights sheet's only source of database state.
//
// Shape copied from `InsightStore`: `@Observable final class`, `@ObservationIgnored private var
// bridge`, `configure(bridge:)`.
//
// Two deliberate departures from that precedent:
//  1. **No polling.** These aggregates are historical, so they load once when the sheet opens.
//     Nothing in this file schedules repeating work, and this store is never joined to the 30 s
//     aggregate poll in `InsightStore` — Plan 33 anti-pattern 6.
//  2. **One request for the whole sheet.** `GET /api/usage/snapshot` composes what used to be
//     seven statements in `OrbitDBReader`, measured at 0.106 s against the live 228 MB store
//     (`docs/bridge-api-additions.md` route 6).
//
// Plan 33's third departure — "no daemon", the sheet worked with the daemon stopped — no longer
// holds and could not: plan 51 decision D1 makes the daemon the only process that can read the
// encrypted store. The configured model still comes from `~/.orbit/.env`, not `/api/llm/models`.
//
// Routines are deliberately absent: they already live in `InsightStore.routines`, and the view
// builds `RoutineTally` from that. A second copy loaded here would be a second source of truth.
@Observable
final class UsageInsightsStore {
    var snapshot: UsageSnapshot = .empty
    var isLoading = false
    var errorMessage: String?
    /// When `snapshot` was fetched. Drives the 60 s no-op window in `load(force:)`.
    var loadedAt: Date?

    private(set) var currentStreak = 0
    private(set) var longestStreak = 0

    /// Favourite = most-called model in the window; nil when there are no calls.
    ///
    /// `snapshot.models` is already ordered by call count (the route orders by `calls DESC`), and the
    /// view must always render `successRate` alongside: the table contains failing and junk model
    /// tags, so call volume alone never means "working" (Plan 33 anti-pattern 11).
    var favouriteModel: ModelUsage? { snapshot.models.first }

    /// From `~/.orbit/.env`, not the daemon (`LLMPreferencesService.swift:52`).
    var configuredModel: String? { LLMPreferencesService.shared.localModelName() }

    @ObservationIgnored private var bridge: OrbitBridgeProtocol?

    /// A reload inside this window is a no-op unless `force` is set.
    private static let freshnessWindow: TimeInterval = 60
    /// Bounds the streak grid, which now renders as many columns as fit its card's width
    /// (`UsageStreakGrid`, Plan 41-B) instead of a fixed 13. Clamped to 26 weeks / 182 days
    /// (open decision 4) — a display window, not a data horizon (Plan 33 §0.7.3).
    ///
    /// Per-day **atom** counts were dropped from `DayActivity` because 90 days of them cost
    /// ~1.3 s to aggregate (Plan 33 §0.7.2); this raises the *events-only* window from 91 to
    /// 182 days, which is cheap by the same reasoning — events are a single indexed COUNT per
    /// day, not the per-atom join that made the 90-day atom aggregate expensive. See
    /// `plans/1_current/APPUPDATES-PARALLEL-EXECUTION.md` §6 for the measured/reasoned cost of
    /// this change.
    private static let gridDays = 182

    func configure(bridge: OrbitBridgeProtocol) {
        self.bridge = bridge
    }

    /// Fetch the whole sheet once. Call it when the sheet opens.
    ///
    /// The read no longer needs a detached task: it is one `URLSession` request that already
    /// suspends instead of blocking, so the main actor is free for its whole duration. (The
    /// previous version hopped off-main because the composed GRDB read measured 612 ms on a
    /// synthetic 90-day store — Plan 33 §0.7.2 — which would have frozen the window.) The
    /// streak arithmetic that remains here is a set walk over at most 182 days.
    ///
    /// `now` and `calendar` are still captured **once**, on the main actor, so the streak's
    /// `today` cannot drift mid-load across a midnight boundary. The same instant reaches the
    /// daemon's day bounds as the `day` parameter, so a rollover cannot scope the "today"
    /// counters to one day while the streak is anchored on another.
    @MainActor
    func load(force: Bool = false) async {
        guard !isLoading else { return }

        let now = Date()
        let calendar = Calendar.current
        if !force, let loadedAt, now.timeIntervalSince(loadedAt) < Self.freshnessWindow {
            return
        }

        guard let bridge else {
            errorMessage = OrbitBridgeError.daemonOffline.localizedDescription
            return
        }

        isLoading = true

        do {
            let loaded = try await bridge.fetchUsageSnapshot(
                days: Self.gridDays,
                breakdownDays: 30,
                appLimit: 8,
                day: Self.localDayString(for: now, calendar: calendar)
            )
            let activeDays = Set(loaded.days.map(\.day))
            snapshot = loaded
            currentStreak = UsageStreak.current(days: activeDays, today: now, calendar: calendar)
            longestStreak = UsageStreak.longest(days: activeDays, calendar: calendar)
            // Freshness is measured from the instant the data describes, not from completion.
            loadedAt = now
            errorMessage = nil
        } catch {
            // Keep the previous snapshot: a failed refresh must not blank a populated sheet.
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// The captured instant as the `day` query parameter, so "today" is decided here rather
    /// than by the daemon's own clock a round-trip later.
    private static func localDayString(for date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
