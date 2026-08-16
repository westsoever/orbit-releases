import Foundation

enum AIMode: String, CaseIterable, Identifiable {
    case cloud
    case local
    case byok

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cloud: return "Cloud AI"
        case .local: return "Local model (Ollama)"
        case .byok: return "Your own API key"
        }
    }

    var subtitle: String {
        switch self {
        case .cloud:
            return "Use orbit's cloud service (~40 messages/day on the shared plan)."
        case .local:
            return "Run a model on this Mac via Ollama. Nothing leaves your machine."
        case .byok:
            return "Bring your own OpenRouter API key and model."
        }
    }
}

/// Persists AI routing preferences in ``~/.orbit/.env`` for the Python daemon (`orbit/check/llm.py`).
final class LLMPreferencesService: @unchecked Sendable {
    static let shared = LLMPreferencesService()

    static let defaultLocalModel = "llama3.1"
    static let defaultOllamaBaseURL = "http://localhost:11434/v1"
    /// Mirrors `_BYOK_MODEL_DEFAULT` in `orbit/check/llm.py:34`.
    static let defaultBYOKModel = "anthropic/claude-sonnet-4.5"

    private let providerKey = "ORBIT_LLM_PROVIDER"
    private let localModelKey = "ORBIT_LOCAL_LLM_MODEL"
    private let localBaseURLKey = "ORBIT_LOCAL_LLM_BASE_URL"
    private let byokModelKey = "ORBIT_BYOK_MODEL"
    private let apiKeyKey = "OPENROUTER_API_KEY"

    func currentMode() -> AIMode? {
        guard let provider = envValue(for: providerKey) else {
            if CloudAIService.shared.isEnabled() { return .cloud }
            return nil
        }
        switch provider.lowercased() {
        case "local":
            return localModelName() != nil ? .local : nil
        case "cloud":
            return CloudAIService.shared.isEnabled() ? .cloud : nil
        case "byok":
            return hasAPIKey() ? .byok : nil
        default:
            return nil
        }
    }

    func localModelName() -> String? {
        guard let value = envValue(for: localModelKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    /// Model slug only — the API key itself is never read back for display (write-only in the UI).
    func byokModelName() -> String? {
        guard let value = envValue(for: byokModelKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    func isLocalConfigured() -> Bool {
        currentMode() == .local
    }

    func isBYOKConfigured() -> Bool {
        currentMode() == .byok
    }

    func configureLocal(model: String) throws {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LLMPreferencesError.emptyModelName
        }
        try CloudAIService.shared.disable()
        try writeEnv {
            $0[providerKey] = "local"
            $0[localModelKey] = trimmed
            $0[localBaseURLKey] = Self.defaultOllamaBaseURL
        }
    }

    /// `apiKey` is written to ``~/.orbit/.env`` at 0600 (`persistEnv`) — never the keychain,
    /// per the recorded storage decision. `model` defaults to `anthropic/claude-sonnet-4.5`
    /// in the UI; both fields are required here.
    func configureBYOK(apiKey: String, model: String) throws {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw LLMPreferencesError.emptyAPIKey
        }
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            throw LLMPreferencesError.emptyModelName
        }
        try CloudAIService.shared.disable()
        try writeEnv {
            $0[providerKey] = "byok"
            $0[byokModelKey] = trimmedModel
            $0[apiKeyKey] = trimmedKey
        }
    }

    func configureCloud() async throws {
        _ = try await CloudAIService.shared.register()
        try writeEnv {
            $0[providerKey] = "cloud"
            $0[localModelKey] = nil
            $0[localBaseURLKey] = nil
        }
    }

    func disableAll() throws {
        try CloudAIService.shared.disable()
        try writeEnv {
            $0[providerKey] = nil
            $0[localModelKey] = nil
            $0[localBaseURLKey] = nil
            $0[byokModelKey] = nil
            $0[apiKeyKey] = nil
        }
    }

    private func hasAPIKey() -> Bool {
        guard let value = envValue(for: apiKeyKey)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !value.isEmpty
    }

    private func envValue(for key: String) -> String? {
        guard let text = try? String(contentsOf: OrbitPaths.envFileURL, encoding: .utf8) else {
            return nil
        }
        let prefix = "\(key)="
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(prefix) {
                let value = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    private func writeEnv(_ mutate: (inout [String: String?]) -> Void) throws {
        try OrbitPaths.ensureOrbitDirectoryExists()
        var values = readManagedEnv()
        mutate(&values)
        try persistEnv(values)
    }

    private func readManagedEnv() -> [String: String?] {
        var values: [String: String?] = [
            providerKey: nil,
            localModelKey: nil,
            localBaseURLKey: nil,
            byokModelKey: nil,
            apiKeyKey: nil,
        ]
        guard let text = try? String(contentsOf: OrbitPaths.envFileURL, encoding: .utf8) else {
            return values
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq])
            let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if values.keys.contains(key) {
                values[key] = value.isEmpty ? nil : value
            }
        }
        return values
    }

    private func persistEnv(_ managed: [String: String?]) throws {
        var preserved: [String] = []
        if FileManager.default.fileExists(atPath: OrbitPaths.envFileURL.path),
           let text = try? String(contentsOf: OrbitPaths.envFileURL, encoding: .utf8) {
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = String(line).trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") {
                    preserved.append(String(line))
                    continue
                }
                guard let eq = trimmed.firstIndex(of: "=") else {
                    preserved.append(String(line))
                    continue
                }
                let key = String(trimmed[..<eq])
                if managed.keys.contains(key) { continue }
                preserved.append(String(line))
            }
        }

        var lines = preserved
        while lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            lines.removeLast()
        }

        let orderedKeys = [providerKey, localModelKey, localBaseURLKey, byokModelKey, apiKeyKey]
        for key in orderedKeys {
            guard let value = managed[key], let value, !value.isEmpty else { continue }
            lines.append("\(key)=\(value)")
        }

        let body = lines.joined(separator: "\n")
        let output = body.isEmpty ? "" : body + "\n"
        try output.write(to: OrbitPaths.envFileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: OrbitPaths.envFileURL.path
        )
    }
}

enum LLMPreferencesError: LocalizedError {
    case emptyModelName
    case emptyAPIKey
    case providerSwitchTimeout

    var errorDescription: String? {
        switch self {
        case .emptyModelName:
            return "Enter the Ollama model name (for example llama3.1)."
        case .emptyAPIKey:
            return "Enter your OpenRouter API key."
        case .providerSwitchTimeout:
            return "Saved your preference, but orbit's background service did not switch providers in time. Try Stop/Start in the CAPTURE sidebar."
        }
    }
}
