import Foundation

/// Decoded from `/api/tasks/pending`, `/api/tasks/kanban` and `/api/task/<id>`. It used to
/// double as a GRDB `FetchableRecord` for the offline direct-SQLite fallback; that fallback
/// is gone (plan 51 decision D1 — the daemon owns the database), so this is now a plain
/// wire model.
struct TaskLogEntry: Codable, Identifiable, Sendable {
    let id: Int64
    let timestamp: String
    let title: String?
    let description: String?
    let originalPrompt: String?
    let approvedPrompt: String?
    let agentType: String?
    let status: String
    let exitCode: Int?

    enum CodingKeys: String, CodingKey {
        case id, timestamp, title, description, status
        case originalPrompt = "original_prompt"
        case approvedPrompt = "approved_prompt"
        case agentType = "agent_type"
        case exitCode = "exit_code"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int64.self, forKey: .id)
        timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        originalPrompt = try container.decodeIfPresent(String.self, forKey: .originalPrompt)
        approvedPrompt = try container.decodeIfPresent(String.self, forKey: .approvedPrompt)
        agentType = try container.decodeIfPresent(String.self, forKey: .agentType)
        status = try container.decode(String.self, forKey: .status)
        exitCode = try container.decodeIfPresent(Int.self, forKey: .exitCode)
    }

    init(
        id: Int64,
        timestamp: String = "",
        title: String? = nil,
        description: String? = nil,
        originalPrompt: String? = nil,
        approvedPrompt: String? = nil,
        agentType: String? = nil,
        status: String,
        exitCode: Int? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.title = title
        self.description = description
        self.originalPrompt = originalPrompt
        self.approvedPrompt = approvedPrompt
        self.agentType = agentType
        self.status = status
        self.exitCode = exitCode
    }

    var typedAgent: AgentType? {
        AgentType(rawValueOrNil: agentType)
    }
}
