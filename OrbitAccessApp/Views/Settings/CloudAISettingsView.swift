import SwiftUI

struct CloudAISettingsView: View {
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
        VStack(alignment: .leading, spacing: 16) {
            Text("AI answers")
                .font(.headline)

            Picker("Mode", selection: $selectedMode) {
                ForEach(AIMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(selectedMode.subtitle)
                .font(.caption)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))

            switch selectedMode {
            case .cloud:
                cloudSection
            case .local:
                localSection
            case .byok:
                byokSection
            }

            HStack(spacing: 12) {
                Button(action: saveSelection) {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Save")
                    }
                }
                .buttonStyle(OrbitFlatButtonStyle(variant: .primary))
                .disabled(isSaving || !canSave)

                if model.hasConfiguredAI {
                    Button("Turn off AI") {
                        Task { await disableAI() }
                    }
                    .buttonStyle(OrbitFlatButtonStyle(variant: .secondary))
                    .disabled(isSaving)
                }
            }

            Button("Open ~/.orbit folder") {
                CloudAIService.shared.openOrbitDirectory()
            }
            .font(.caption)
            .buttonStyle(.link)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(Color.orbitScoreRed)
            }

            // `AccountSettingsView()` used to render here. Plan 53 Phase 6 moved it to its own
            // Settings › Account tab (`AccountTabView`) — the account is not a Cloud AI
            // setting, and the profile questionnaire needed a findable home beside it.
        }
        .padding()
        .frame(maxWidth: 420, alignment: .leading)
        .background(Color.orbitCanvas(for: colorScheme))
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

    private var cloudSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Context snippets from your question are sent to orbit's AI service. Nothing else leaves your Mac.")
                .font(.caption)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
            if model.isCloudAIEnabled {
                Text("Cloud AI is active on this Mac.")
                    .font(.caption)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
            }
        }
    }

    private var localSection: some View {
        LocalModelPickerSection(
            localModelName: $localModelName,
            availableModels: availableModels,
            useCustomModel: $useCustomModel,
            readinessHint: model.localModelHint
        )
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

    @MainActor
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
                errorMessage = ChatErrorFormatter.aiSetupMessage(for: error)
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

    @MainActor
    private func disableAI() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try LLMPreferencesService.shared.disableAll()
            model.refreshAIState()
        } catch {
            errorMessage = ChatErrorFormatter.userMessage(for: error)
        }
    }
}
