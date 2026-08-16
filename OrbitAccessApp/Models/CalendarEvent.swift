import Foundation

struct CalendarEvent: Identifiable, Sendable {
    let id: String
    let title: String
    let start: Date
    let end: Date
}
