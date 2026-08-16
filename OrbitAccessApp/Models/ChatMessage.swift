import Foundation

enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

struct ChatMessage: Identifiable, Sendable {
    let id: UUID
    let role: MessageRole
    var content: String
    let timestamp: Date
    var sourceAtoms: [SearchHit]

    init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        timestamp: Date = Date(),
        sourceAtoms: [SearchHit] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.sourceAtoms = sourceAtoms
    }
}

extension ChatMessage: Codable {}

struct ChatChunk: Sendable {
    enum Kind: Sendable {
        case text(String)
        case sources([SearchHit])
        case done
    }

    let kind: Kind
}
