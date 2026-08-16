import Foundation

enum SidebaneSection: String, CaseIterable, Identifiable {
    case agents
    case capture
    case privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .agents: return "AGENTS"
        case .capture: return "CAPTURE"
        case .privacy: return "PRIVACY"
        }
    }
}

struct AIFunctionContext {
    let chatStore: ChatStore
    let canBrowseContext: Bool
    let canUseLiveServices: Bool

    @MainActor
    func prefillChat(_ text: String) {
        // Route through prefillInput, not a bare inputText write: its nil `model:` default
        // clears any pending routine model override. Assigning inputText directly would leave
        // a routine's override armed for whatever the user types next.
        chatStore.prefillInput(text)
        chatStore.requestFocus()
    }

    @MainActor
    func requestChatFocus() {
        chatStore.requestFocus()
    }
}

protocol AIFunction: Identifiable {
    var id: String { get }
    var title: String { get }
    var icon: String { get }
    var section: SidebaneSection { get }
    func execute(_ context: AIFunctionContext) async
}
