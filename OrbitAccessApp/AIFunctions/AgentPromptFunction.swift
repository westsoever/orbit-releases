import Foundation

struct AgentPromptFunction: AIFunction {
    let agentType: AgentType

    var id: String { "agent-\(agentType.rawValue)" }
    var title: String { agentType.displayName }
    var icon: String { agentType.icon }
    var section: SidebaneSection { .agents }

    func execute(_ context: AIFunctionContext) async {
        await MainActor.run {
            context.prefillChat("\(agentType.displayName): ")
        }
    }
}
