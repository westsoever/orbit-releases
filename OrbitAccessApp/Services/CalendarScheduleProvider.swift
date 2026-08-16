import Foundation

// EventKit local calendar integration — see plans/completed/03-universal-capture.md:308 (Phase 4C).

protocol CalendarScheduleProvider: Sendable {
    var isConnected: Bool { get }
    func todayEvents() async throws -> [CalendarEvent]
}

struct DisconnectedCalendarProvider: CalendarScheduleProvider {
    var isConnected: Bool { false }

    func todayEvents() async throws -> [CalendarEvent] { [] }
}
