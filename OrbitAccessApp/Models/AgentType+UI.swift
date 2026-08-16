import SwiftUI

extension AgentType {
    var color: Color {
        switch self {
        case .writing: return Color.orbitAgentWriting
        case .research: return Color.orbitAgentResearch
        case .code: return Color.orbitAgentCode
        case .admin: return Color.orbitAgentAdmin
        case .data: return Color.orbitAgentData
        case .communication: return Color.orbitAgentCommunication
        }
    }

    var icon: String {
        switch self {
        case .writing: return "pencil.line"
        case .research: return "magnifyingglass"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .admin: return "gearshape"
        case .data: return "chart.bar"
        case .communication: return "bubble.left.and.bubble.right"
        }
    }

    var displayName: String { rawValue.capitalized }
    var chatTemplate: String { "\(displayName): " }
}
