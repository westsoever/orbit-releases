import Foundation

/// The five sidecard widgets that can appear in the right-hand column.
enum SidecardWidget: String, Codable, CaseIterable, Identifiable, Sendable {
    case todaySummary
    case recommendedTasks
    case todaysSchedule
    case routines
    case contextStream

    var id: String { rawValue }

    var title: String {
        switch self {
        case .todaySummary: return "Today"
        case .recommendedTasks: return "Recommended Tasks"
        case .todaysSchedule: return "Today's Schedule"
        case .routines: return "Routines"
        case .contextStream: return "Context Stream"
        }
    }

    var systemImage: String {
        switch self {
        case .todaySummary: return "sun.max"
        case .recommendedTasks: return "checklist"
        case .todaysSchedule: return "calendar"
        case .routines: return "repeat"
        case .contextStream: return "clock.arrow.circlepath"
        }
    }
}

/// One row in the persisted sidecard layout: which widget, whether it's shown, and whether it's collapsed.
struct SidecardLayoutEntry: Codable, Identifiable, Equatable, Sendable {
    let widget: SidecardWidget
    var isVisible: Bool
    var isCollapsed: Bool

    var id: String { widget.rawValue }
}
