import SwiftUI

struct CloudAIEnableCard: View {
    @Environment(AppViewModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedMode: AIMode = .cloud
    @State private var localModelName = LLMPreferencesService.defaultLocalModel
    @State private var availableModels: [String] = []
    @State private var useCustomModel = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var byokAPIKey = ""
    @State private var byokModel = LLMPreferencesService.defaultBYOKModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose how orbit answers")
                .font(.subheadline.weight(.semibold))

            Picker("AI mode", selection: $selectedMode) {
                ForEach(AIMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(selectedMode.subtitle)
                .font(.caption)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))

            if selectedMode == .local {
                LocalModelPickerSection(
                    localModelName: $localModelName,
                    availableModels: availableModels,
                    useCustomModel: $useCustomModel,
                    modelLabel: "Ollama model name",
                    helpText: "Run `ollama serve`, then `ollama pull \(localModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "llama3.1" : localModelName)`.",
                    readinessHint: model.localModelHint
                )
            } else if selectedMode == .byok {
                byokSection
            }

            HStack(spacing: 12) {
                Button(action: saveSelection) {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(saveButtonTitle)
                    }
                }
                .buttonStyle(OrbitFlatButtonStyle(variant: .primary))
                .disabled(isSaving || !canSave)

                Button("Settings…") {
                    model.showCloudAISettings = true
                }
                .buttonStyle(OrbitFlatButtonStyle(variant: .secondary))
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(Color.orbitScoreRed)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .orbitCardChrome(colorScheme: colorScheme)
        .task { await hydrateLocalModels() }
        .onAppear {
            if let mode = model.userAIMode ?? model.aiMode {
                selectedMode = mode
            }
            if let modelName = model.localModelName {
                localModelName = modelName
            }
            if let byokModelName = LLMPreferencesService.shared.byokModelName() {
                byokModel = byokModelName
            }
        }
    }

    private var byokSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OpenRouter API key")
                .font(.caption.weight(.medium))
            SecureField("sk-or-...", text: $byokAPIKey)
                .textFieldStyle(.plain)
                .font(.callout)
                .padding(10)
                .background(Color.clear, in: RoundedRectangle(cornerRadius: OrbitShape.radiusControl))
                .orbitHairlineBorder(cornerRadius: OrbitShape.radiusControl, colorScheme: colorScheme)

            Text("Model slug")
                .font(.caption.weight(.medium))
            TextField(LLMPreferencesService.defaultBYOKModel, text: $byokModel)
                .textFieldStyle(.plain)
                .font(.callout)
                .padding(10)
                .background(Color.clear, in: RoundedRectangle(cornerRadius: OrbitShape.radiusControl))
                .orbitHairlineBorder(cornerRadius: OrbitShape.radiusControl, colorScheme: colorScheme)

            Text("Stored in ~/.orbit/.env (file permissions 0600). Never sent anywhere but OpenRouter.")
                .font(.caption2)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
        }
    }

    private var saveButtonTitle: String {
        switch selectedMode {
        case .cloud: return "Enable Cloud AI"
        case .local: return "Use local model"
        case .byok: return "Use my API key"
        }
    }

    private var canSave: Bool {
        switch selectedMode {
        case .cloud:
            return true
        case .local:
            return !localModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .byok:
            return !byokAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !byokModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    @MainActor
    private func hydrateLocalModels() async {
        let models = await loadAvailableLocalModels(bridge: model.bridge)
        availableModels = models
        applyHydratedLocalModelSelection(
            models: models,
            localModelName: &localModelName,
            useCustomModel: &useCustomModel
        )
    }

    private func saveSelection() {
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                switch selectedMode {
                case .cloud:
                    try await LLMPreferencesService.shared.configureCloud()
                case .local:
                    try LLMPreferencesService.shared.configureLocal(model: localModelName)
                case .byok:
                    try LLMPreferencesService.shared.configureBYOK(apiKey: byokAPIKey, model: byokModel)
                }
                try await model.confirmProviderSwitch(expectedMode: selectedMode)
                if selectedMode == .byok {
                    try await probeBYOK()
                }
            } catch {
                await MainActor.run {
                    errorMessage = ChatErrorFormatter.aiSetupMessage(for: error)
                }
            }
        }
    }

    /// One cheap completion round-trip so a bad OpenRouter key/slug is caught at save time
    /// instead of surfacing on the user's first real chat message (§0.1 Defect A analogue
    /// for BYOK). Reuses the existing `/api/chat` path — no new endpoint.
    @MainActor
    private func probeBYOK() async throws {
        for try await _ in model.bridge.chatStream("Reply with OK.", model: nil) {}
    }
}
