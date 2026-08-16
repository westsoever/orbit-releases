import Foundation

final class AIFunctionRegistry: @unchecked Sendable {
    static let shared = AIFunctionRegistry()

    private(set) var functions: [any AIFunction] = []
    private let lock = NSLock()

    private init() {}

    func register(_ function: any AIFunction) {
        lock.lock()
        defer { lock.unlock() }
        functions.append(function)
    }

    func grouped() -> [SidebaneSection: [any AIFunction]] {
        lock.lock()
        defer { lock.unlock() }
        return Dictionary(grouping: functions, by: \.section)
    }
}
