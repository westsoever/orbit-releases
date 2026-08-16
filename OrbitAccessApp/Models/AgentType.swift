import Foundation

enum AgentType: String, CaseIterable, Codable, Identifiable {
    case writing
    case research
    case code
    case admin
    case data
    case communication

    var id: String { rawValue }

    init?(rawValueOrNil: String?) {
        guard let rawValueOrNil else { return nil }
        self.init(rawValue: rawValueOrNil)
    }
}
