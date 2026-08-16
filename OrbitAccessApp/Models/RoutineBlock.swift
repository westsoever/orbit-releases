import Foundation

enum RoutineFrequency: String, Codable, CaseIterable, Sendable {
    case daily
    case weekly
    case monthly

    var displayName: String {
        switch self {
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        }
    }
}

enum RoutineMode: String, Codable, CaseIterable, Sendable {
    case quick
    case regular
    case max

    var displayName: String {
        switch self {
        case .quick: return "Quick"
        case .regular: return "Regular"
        case .max: return "Max"
        }
    }
}

enum RoutineRunState: String, Codable, Sendable {
    case idle
    case running
}

struct RoutineBlock: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var frequency: RoutineFrequency
    /// ISO weekdays: 1=Mon … 7=Sun
    var weekdays: [Int]
    var monthDay: Int
    /// Local fire time as `"HH:mm"`.
    var time: String
    /// Legacy end of active window as `"HH:mm"` (deep-work blocks, Plan 27 and earlier).
    /// Retired by Plan 43-A: routines fire at a single `time` now. Kept only so
    /// `routines.json` files that still carry the key keep decoding — never written on encode.
    var endTime: String?
    /// Legacy depth enum — kept for `routines.json` backward compat; UI replaced in Plan 27 P3.
    var mode: RoutineMode
    /// Ollama / app model tag; `nil` = use the app default. Free-form (discovered at runtime).
    var model: String?
    var notifyOnReady: Bool
    var emailOnReady: Bool
    var instructions: String
    var lastCompletedAt: Date?
    var runState: RoutineRunState

    init(
        id: String = UUID().uuidString,
        title: String = "",
        frequency: RoutineFrequency = .weekly,
        weekdays: [Int] = [],
        monthDay: Int = 1,
        time: String = "09:00",
        endTime: String? = nil,
        mode: RoutineMode = .quick,
        model: String? = nil,
        notifyOnReady: Bool = true,
        emailOnReady: Bool = false,
        instructions: String = "",
        lastCompletedAt: Date? = nil,
        runState: RoutineRunState = .idle
    ) {
        self.id = id
        self.title = title
        self.frequency = frequency
        self.weekdays = weekdays
        self.monthDay = monthDay
        self.time = time
        self.endTime = endTime
        self.mode = mode
        self.model = model
        self.notifyOnReady = notifyOnReady
        self.emailOnReady = emailOnReady
        self.instructions = instructions
        self.lastCompletedAt = lastCompletedAt
        self.runState = runState
    }

    /// Legacy convenience used by seed data (`startTime`/`endTime` window blocks).
    init(id: String, title: String, startTime: String, endTime: String) {
        self.init(
            id: id,
            title: title,
            frequency: .daily,
            weekdays: Array(1...7),
            monthDay: 1,
            time: startTime,
            endTime: endTime,
            mode: .regular,
            model: nil,
            notifyOnReady: false,
            emailOnReady: false,
            instructions: "",
            lastCompletedAt: nil,
            runState: .idle
        )
    }

    static func blank(calendar: Calendar = .current, now: Date = Date()) -> RoutineBlock {
        let weekday = RoutineSchedule.orbitWeekday(from: now, calendar: calendar)
        let day = calendar.component(.day, from: now)
        return RoutineBlock(
            id: UUID().uuidString,
            title: "",
            frequency: .weekly,
            weekdays: [weekday],
            monthDay: day,
            time: "09:00",
            endTime: nil,
            mode: .quick,
            model: nil,
            notifyOnReady: true,
            emailOnReady: false,
            instructions: "",
            lastCompletedAt: nil,
            runState: .idle
        )
    }
}

// MARK: - Codable (backward-compatible with old routines.json)

extension RoutineBlock: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, title, frequency, weekdays, monthDay, time, endTime
        case startTime, mode, model, notifyOnReady, emailOnReady, instructions
        case lastCompletedAt, runState, isActiveNow
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Routine"
        frequency = try c.decodeIfPresent(RoutineFrequency.self, forKey: .frequency) ?? .daily
        weekdays = try c.decodeIfPresent([Int].self, forKey: .weekdays) ?? Array(1...7)
        monthDay = try c.decodeIfPresent(Int.self, forKey: .monthDay) ?? 1

        if let t = try c.decodeIfPresent(String.self, forKey: .time) {
            time = t
        } else if let start = try c.decodeIfPresent(String.self, forKey: .startTime) {
            time = start
        } else {
            time = "09:00"
        }

        endTime = try c.decodeIfPresent(String.self, forKey: .endTime)
        // Legacy files always have `mode`; missing → .quick. Never throw on old keys.
        mode = try c.decodeIfPresent(RoutineMode.self, forKey: .mode) ?? .quick
        // New field: absent in pre-Plan-27 files → nil (app default).
        model = try c.decodeIfPresent(String.self, forKey: .model)
        notifyOnReady = try c.decodeIfPresent(Bool.self, forKey: .notifyOnReady) ?? false
        emailOnReady = try c.decodeIfPresent(Bool.self, forKey: .emailOnReady) ?? false
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        runState = try c.decodeIfPresent(RoutineRunState.self, forKey: .runState) ?? .idle

        // Encode writes ISO-8601 strings; decodeIfPresent(Date.self) throws on String
        // (typeMismatch), which would fail the whole array and make load() return [].
        if let raw = try? c.decode(String.self, forKey: .lastCompletedAt) {
            lastCompletedAt = ISO8601DateFormatter().date(from: raw) ?? raw.orbitParsedDate
        } else if let date = try? c.decode(Date.self, forKey: .lastCompletedAt) {
            lastCompletedAt = date
        } else {
            lastCompletedAt = nil
        }
        // isActiveNow intentionally ignored (computed).
        _ = try c.decodeIfPresent(Bool.self, forKey: .isActiveNow)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(frequency, forKey: .frequency)
        try c.encode(weekdays, forKey: .weekdays)
        try c.encode(monthDay, forKey: .monthDay)
        try c.encode(time, forKey: .time)
        // endTime is retired (Plan 43-A): routines fire at a single time now. We never write
        // this key on encode, even if a legacy value is still sitting in memory — only the
        // decode side (above) still reads it, for routines.json files saved before this change.
        try c.encode(mode, forKey: .mode)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encode(notifyOnReady, forKey: .notifyOnReady)
        try c.encode(emailOnReady, forKey: .emailOnReady)
        try c.encode(instructions, forKey: .instructions)
        try c.encode(runState, forKey: .runState)
        if let lastCompletedAt {
            try c.encode(ISO8601DateFormatter().string(from: lastCompletedAt), forKey: .lastCompletedAt)
        }
    }
}

// MARK: - Schedule helpers

enum RoutineSchedule {
    static let dayChipLabels = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]
    static let dayShortNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    /// Convert Calendar weekday (1=Sun…7=Sat) to Orbit weekday (1=Mon…7=Sun).
    static func orbitWeekday(from date: Date, calendar: Calendar = .current) -> Int {
        let cal = calendar.component(.weekday, from: date)
        return cal == 1 ? 7 : cal - 1
    }

    static func parseClock(_ hhmm: String, on day: Date, calendar: Calendar = .current) -> Date? {
        let parts = hhmm.split(separator: ":")
        guard parts.count >= 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }

    static func displayTime(_ hhmm: String, calendar: Calendar = .current, now: Date = Date()) -> String {
        guard let date = parseClock(hhmm, on: now, calendar: calendar) else { return hhmm }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    static func isScheduledToday(
        _ routine: RoutineBlock,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        switch routine.frequency {
        case .daily:
            return true
        case .weekly:
            let today = orbitWeekday(from: now, calendar: calendar)
            return routine.weekdays.contains(today)
        case .monthly:
            let day = calendar.component(.day, from: now)
            let daysInMonth = calendar.range(of: .day, in: .month, for: now)?.count ?? 31
            let target = min(max(routine.monthDay, 1), daysInMonth)
            return day == target
        }
    }

    /// Active when running, or inside today's schedule window.
    /// Plan 43-A retires the `[time, endTime]` window for anything the app writes — new and
    /// edited routines carry a single fire time, so this always falls through to the ±15
    /// minute rule for them. The `endTime` arm survives only to keep legacy rows that still
    /// have the key on disk (pre-43-A `routines.json`) behaving the way they always did; it
    /// disappears the moment such a routine is re-saved, since encode no longer writes the key.
    static func isActive(
        _ routine: RoutineBlock,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        if routine.runState == .running { return true }
        guard isScheduledToday(routine, now: now, calendar: calendar) else { return false }
        guard let start = parseClock(routine.time, on: now, calendar: calendar) else { return false }

        if let endRaw = routine.endTime, let end = parseClock(endRaw, on: now, calendar: calendar) {
            if end >= start {
                return now >= start && now <= end
            }
            // Overnight window
            return now >= start || now <= end
        }

        let window: TimeInterval = 15 * 60
        return abs(now.timeIntervalSince(start)) <= window
    }

    static func isCompletedToday(
        _ routine: RoutineBlock,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard let completed = routine.lastCompletedAt else { return false }
        return calendar.isDate(completed, inSameDayAs: now)
    }

    static func scheduleSummary(
        _ routine: RoutineBlock,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> String {
        let freq = routine.frequency.displayName
        let days: String
        switch routine.frequency {
        case .daily:
            days = "Every day"
        case .weekly:
            let sorted = routine.weekdays.filter { (1...7).contains($0) }.sorted()
            if sorted.isEmpty {
                days = "No days"
            } else if sorted.count == 7 {
                days = "Every day"
            } else {
                days = sorted.map { dayShortNames[$0 - 1] }.joined(separator: ", ")
            }
        case .monthly:
            days = "Day \(max(1, min(routine.monthDay, 31)))"
        }
        // Plan 43-A: always a single fire time, never a range — even for legacy rows that
        // still carry `endTime` on disk. That key is display-dead now; it only exists so
        // decode doesn't fail on old routines.json files.
        let timeStr = displayTime(routine.time, calendar: calendar, now: now)
        return "\(freq) · \(days) · \(timeStr)"
    }
}

extension RoutineBlock {
    func isScheduledToday(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        RoutineSchedule.isScheduledToday(self, now: now, calendar: calendar)
    }

    func isActive(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        RoutineSchedule.isActive(self, now: now, calendar: calendar)
    }

    func isCompletedToday(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        RoutineSchedule.isCompletedToday(self, now: now, calendar: calendar)
    }

    var scheduleSummary: String {
        RoutineSchedule.scheduleSummary(self)
    }
}
