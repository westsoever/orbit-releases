import SwiftUI

struct LocalModelPickerSection: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var localModelName: String
    let availableModels: [String]
    @Binding var useCustomModel: Bool
    var modelLabel: String = "Model name"
    var helpText: String?
    /// Daemon preflight warning (model not pulled / Ollama down). Nil when ready.
    var readinessHint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(modelLabel)
                .font(.caption.weight(.medium))

            if !availableModels.isEmpty && !useCustomModel {
                Picker("Model", selection: $localModelName) {
                    ForEach(availableModels, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()

                Button("Enter model name manually") {
                    useCustomModel = true
                }
                .font(.caption)
                .buttonStyle(.link)
            } else {
                TextField("llama3.1", text: $localModelName)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .padding(10)
                    .background(Color.clear, in: RoundedRectangle(cornerRadius: OrbitShape.radiusControl))
                    .orbitHairlineBorder(cornerRadius: OrbitShape.radiusControl, colorScheme: colorScheme)

                if !availableModels.isEmpty {
                    Button("Choose from installed models") {
                        useCustomModel = false
                        if !availableModels.contains(localModelName),
                           let first = availableModels.first {
                            localModelName = first
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.link)
                }
            }

            if let readinessHint {
                Text(readinessHint)
                    .font(.caption2)
                    .foregroundStyle(Color.orbitScoreRed)
            }

            Text(helpText ?? "Chat uses Ollama at \(LLMPreferencesService.defaultOllamaBaseURL). Start it with `ollama serve`.")
                .font(.caption2)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
        }
    }
}

/// After fetching Ollama tags: empty list → custom field; saved name missing from list → custom
/// field (unless still on default/empty, then pick first installed tag for the Picker).
func applyHydratedLocalModelSelection(
    models: [String],
    localModelName: inout String,
    useCustomModel: inout Bool
) {
    if models.isEmpty {
        useCustomModel = true
    } else if !models.contains(localModelName) {
        if localModelName == LLMPreferencesService.defaultLocalModel || localModelName.isEmpty,
           let first = models.first {
            localModelName = first
        } else {
            useCustomModel = true
        }
    }
}

@MainActor
func loadAvailableLocalModels(bridge: OrbitBridgeProtocol) async -> [String] {
    do {
        let response = try await bridge.fetchLocalModels()
        return response.models
    } catch {
        return []
    }
}
