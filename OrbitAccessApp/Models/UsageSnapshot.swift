import Foundation

// Plan 33 Phase 1 — value types for the Usage Insights sheet.
// Plain `Sendable` values only: no view logic, no DB access, no `Date()` anywhere.
//
// Populated by `GET /api/usage/snapshot` (plan 51 decision D1 — the daemon owns the
// database, the app reads over localhost HTTP). The JSON keys are documented in
// `docs/bridge-api-additions.md` route 6; three of them are renamed relative to the SQL
// that produced them (`average_latency_ms`, `ok_calls`, `bundle_id`), so the `CodingKeys`
// below are the contract, not decoration.

/// One captured local day. **Events only** — per-day atom counts cost ~1.3 s at 90-day
/// scale for no benefit, so the streak grid is driven by event counts (Plan 33 §0.7.2).
struct DayActivity: Sendable, Identifiable {
    let day: Date
    let events: Int

    var id: Date { day }
}

/// One app's share of capture. Excludes `com.orbit.access` (Plan 33 anti-pattern 8).
struct AppUsage: Sendable, Identifiable, Decodable {
    let bundleId: String
    let appName: String
    let events: Int
    let atoms: Int

    var id: String { bundleId }

    enum CodingKeys: String, CodingKey {
        case bundleId = "bundle_id"
        case appName = "app_name"
        case events, atoms
    }
}

/// Events grouped by `context_events.capture_method` (`ax`, `ax_enhanced`, `metadata_only`, …).
struct CaptureTierSlice: Sendable, Identifiable, Decodable {
    let method: String
    let events: Int

    var id: String { method }
}

/// `task_log` status counts. `approved` folds in `dispatched`, matching `/api/score/inputs`.
struct TaskTally: Sendable, Decodable {
    let detected: Int
    let approved: Int
    let skipped: Int
}

/// One `llm_calls` model/provider pair. `okCalls` is always shown alongside `calls`:
/// the table contains failing and junk model tags (Plan 33 anti-pattern 11), so call
/// volume alone must never be presented as "working".
struct ModelUsage: Sendable, Identifiable, Decodable {
    let model: String
    let provider: String
    let calls: Int
    let okCalls: Int
    let averageLatencyMs: Int

    var id: String { "\(provider)/\(model)" }

    var successRate: Double { calls > 0 ? Double(okCalls) / Double(calls) : 0 }

    enum CodingKeys: String, CodingKey {
        case model, provider, calls
        case okCalls = "ok_calls"
        case averageLatencyMs = "average_latency_ms"
    }
}

/// Routine counts. `inWindowNow` means *inside today's time window*, not *running* —
/// there is no scheduler (Plan 33 anti-pattern 10). Built by
/// `RoutineTally.from(routines:now:calendar:)` in `UsageStreak.swift`.
struct RoutineTally: Sendable {
    let total: Int
    let scheduledToday: Int
    let inWindowNow: Int
    let completedToday: Int
}

/// Everything the Usage Insights sheet needs from the database, fetched once on open.
struct UsageSnapshot: Sendable, Decodable {
    /// Ascending by day, active days only (days with zero events are absent).
    let days: [DayActivity]
    /// Descending by atoms.
    let apps: [AppUsage]
    /// Descending by events.
    let tiers: [CaptureTierSlice]
    let tasks: TaskTally
    /// Descending by calls.
    let models: [ModelUsage]
    let llmCalls: Int
    let llmOkCalls: Int
    let totalAtoms: Int
    let totalChars: Int
    let distinctApps: Int
    let atomsToday: Int
    let activeHoursToday: Int

    enum CodingKeys: String, CodingKey {
        case days, apps, tiers, tasks, models
        case llmCalls = "llm_calls"
        case llmOkCalls = "llm_ok_calls"
        case totalAtoms = "total_atoms"
        case totalChars = "total_chars"
        case distinctApps = "distinct_apps"
        case atomsToday = "atoms_today"
        case activeHoursToday = "active_hours_today"
    }

    /// `days[].day` on the wire. It is a **local calendar day**, not an instant, so it
    /// arrives as `yyyy-MM-dd` and is parsed here rather than by a `JSONDecoder` date
    /// strategy — the whole snapshot would otherwise need one strategy for this field and
    /// none for the ISO-8601 strings elsewhere.
    private struct DayRow: Decodable {
        let day: String
        let events: Int
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // One formatter for the whole array, built here rather than held as a static: a
        // shared `DateFormatter` is not `Sendable`, and this decode happens once per sheet
        // open.
        let formatter = Self.localDayFormatter()
        days = try container.decode([DayRow].self, forKey: .days).compactMap { row in
            guard let day = formatter.date(from: row.day) else { return nil }
            return DayActivity(day: day, events: row.events)
        }
        apps = try container.decode([AppUsage].self, forKey: .apps)
        tiers = try container.decode([CaptureTierSlice].self, forKey: .tiers)
        tasks = try container.decode(TaskTally.self, forKey: .tasks)
        models = try container.decode([ModelUsage].self, forKey: .models)
        llmCalls = try container.decode(Int.self, forKey: .llmCalls)
        llmOkCalls = try container.decode(Int.self, forKey: .llmOkCalls)
        totalAtoms = try container.decode(Int.self, forKey: .totalAtoms)
        totalChars = try container.decode(Int.self, forKey: .totalChars)
        distinctApps = try container.decode(Int.self, forKey: .distinctApps)
        atomsToday = try container.decode(Int.self, forKey: .atomsToday)
        activeHoursToday = try container.decode(Int.self, forKey: .activeHoursToday)
    }

    /// `en_US_POSIX` + the current time zone: the same formatter the deleted
    /// `OrbitDBReader.localDayFormatter()` used, so a day string maps to the same instant
    /// the streak grid has always drawn it on.
    private static func localDayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    /// Declared explicitly because `init(from:)` above suppresses the synthesised
    /// memberwise initialiser, and `empty` needs it.
    init(
        days: [DayActivity],
        apps: [AppUsage],
        tiers: [CaptureTierSlice],
        tasks: TaskTally,
        models: [ModelUsage],
        llmCalls: Int,
        llmOkCalls: Int,
        totalAtoms: Int,
        totalChars: Int,
        distinctApps: Int,
        atomsToday: Int,
        activeHoursToday: Int
    ) {
        self.days = days
        self.apps = apps
        self.tiers = tiers
        self.tasks = tasks
        self.models = models
        self.llmCalls = llmCalls
        self.llmOkCalls = llmOkCalls
        self.totalAtoms = totalAtoms
        self.totalChars = totalChars
        self.distinctApps = distinctApps
        self.atomsToday = atomsToday
        self.activeHoursToday = activeHoursToday
    }

    static let empty = UsageSnapshot(
        days: [],
        apps: [],
        tiers: [],
        tasks: TaskTally(detected: 0, approved: 0, skipped: 0),
        models: [],
        llmCalls: 0,
        llmOkCalls: 0,
        totalAtoms: 0,
        totalChars: 0,
        distinctApps: 0,
        atomsToday: 0,
        activeHoursToday: 0
    )
}
