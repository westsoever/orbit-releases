import SwiftUI

struct ChatInputBar: View {
    @Environment(AppViewModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    var showSpinOff: Bool = true
    var isCompact: Bool = false

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField(
                placeholderText,
                text: Bindable(model.chatStore).inputText,
                axis: .vertical
            )
            .lineLimit(1...6)
            .textFieldStyle(.plain)
            .font(.body)
            .kerning(-0.1)
            .focused($isFocused)
            .disabled(!canType)
            .onSubmit { sendMessage() }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .frame(minHeight: isCompact ? 44 : 72, alignment: .top)

            OrbitHairlineDivider()

            toolbarRow
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            if !isCompact {
                OrbitHairlineDivider()
                ChatSuggestionChips()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
        .orbitCardChrome(colorScheme: colorScheme)
        .overlay(
            RoundedRectangle(cornerRadius: OrbitShape.radiusCard + 1)
                .stroke(Color.orbitAccent(for: colorScheme).opacity(isFocused ? 0.55 : 0), lineWidth: 1)
                .padding(-1)
        )
        .animation(OrbitMotion.selection, value: isFocused)
        .onChange(of: model.chatStore.focusRequested) { _, requested in
            if requested {
                isFocused = true
                model.chatStore.clearFocusRequest()
            }
        }
    }

    private var toolbarRow: some View {
        HStack(spacing: 8) {
            providerChip

            statusSlot

            if !isCompact {
                attachButton
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                if showSpinOff {
                    spinOffButton
                }
                sendButton
            }
        }
    }

    // MARK: - Status slot (thinking indicator / transient state / credential source)
    //
    // All three states share one ZStack slot and swap via .opacity + .allowsHitTesting so the
    // toolbar row never changes height on a state flip (program §5.2 — NSHostingView size hazard).
    // Precedence: thinking > transient > credential. Same idiom as SidecardHeader's edit toggle.

    private var isThinking: Bool {
        model.chatStore.isStreaming
    }

    private var showTransient: Bool {
        !isThinking && transientStatusText != nil
    }

    private var showCredential: Bool {
        !isThinking && transientStatusText == nil && credentialStatusText != nil
    }

    private var statusSlot: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("orbit is thinking…")
                    .font(.caption)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                    .lineLimit(1)
            }
            .opacity(isThinking ? 1 : 0)
            .allowsHitTesting(false)

            Text(transientStatusText ?? "")
                .font(.caption)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                .lineLimit(1)
                .truncationMode(.middle)
                .opacity(showTransient ? 1 : 0)
                .allowsHitTesting(false)

            Text(credentialStatusText ?? "")
                .font(.caption)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                .lineLimit(1)
                .truncationMode(.middle)
                .opacity(showCredential ? 1 : 0)
                .allowsHitTesting(false)
        }
        .layoutPriority(0)
    }

    /// Transient states occupy the credential label's slot while they apply: the daemon-starting
    /// notice and the browse-only sentence. Copied from the strings `MainChatView.chatStatusText`
    /// used before 40-B tears that computed property down.
    private var transientStatusText: String? {
        if model.isDaemonStarting {
            return "orbit is starting in the background…"
        }
        if !model.canUseAIChat && model.canSearchLocally && !model.canUseLiveServices {
            return "Browse-only mode — keyword search over saved context. Configure AI above for full answers."
        }
        return nil
    }

    /// The credential *source* only — provider identity ("Cloud AI", model name) already lives in
    /// `providerChipLabel`. Exact strings copied from `MainChatView.chatStatusText` before 40-B
    /// deletes that property.
    private var credentialStatusText: String? {
        guard model.canUseAIChat else { return nil }
        if let mode = model.aiMode {
            switch mode {
            case .cloud:
                if model.cloudAI.hasBYOK() {
                    return "Using your API key from ~/.orbit/.env."
                }
                return nil
            case .local:
                if let name = model.effectiveLocalModelName {
                    return "Local Ollama model: \(name)."
                }
                return "Local Ollama model is configured."
            case .byok:
                return "Using your API key from ~/.orbit/.env."
            }
        }
        if model.effectiveLLMProvider == "local" {
            if let name = model.effectiveLocalModelName {
                return "Local Ollama model: \(name)."
            }
            return "Local Ollama model is available."
        }
        if model.cloudAI.hasBYOK() {
            return "Using your API key from ~/.orbit/.env."
        }
        return nil
    }

    private var providerChip: some View {
        Button {
            model.showCloudAISettings = true
        } label: {
            Text(providerChipLabel)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .buttonStyle(OrbitFlatButtonStyle(variant: .ghost, size: .sm))
        .help("Switch AI provider (Cloud AI or local Ollama model)")
    }

    private var providerChipLabel: String {
        if model.userAIMode == .cloud || model.aiMode == .cloud {
            return "Cloud AI"
        }
        if model.userAIMode == .local || model.aiMode == .local || model.effectiveLLMProvider == "local" {
            if let name = model.effectiveLocalModelName {
                return name
            }
            return "Local model"
        }
        if model.effectiveLLMProvider == "relay" || model.effectiveLLMProvider == "byok" {
            return "Cloud AI"
        }
        return "AI provider"
    }

    private var attachButton: some View {
        Button {} label: {
            Image(systemName: "paperclip")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(true)
        .help("Attachments coming soon")
    }

    private var canType: Bool {
        model.canBrowseContext || model.canUseLiveServices
    }

    private var placeholderText: String {
        if model.isDaemonStarting {
            return "orbit is starting…"
        }
        if !model.canBrowseContext {
            // `canBrowseContext` tracks daemon reachability now — the app no longer opens the
            // database itself, so naming the database here pointed at the wrong thing.
            return "Waiting for the orbit daemon…"
        }
        if model.canUseAIChat {
            let isLocal = model.aiMode == .local || model.effectiveLLMProvider == "local"
            if isLocal, let name = model.effectiveLocalModelName {
                return "Ask orbit anything… (local: \(name))"
            }
            if model.aiMode == .cloud {
                return "Ask orbit anything… (Cloud AI)"
            }
            return "Ask orbit anything…"
        }
        if model.canSearchLocally {
            return "Search your saved context (configure AI above for full answers)…"
        }
        return "orbit is starting…"
    }

    private var sendButton: some View {
        Button(action: sendMessage) {
            Image(systemName: "arrow.up")
                .font(.system(size: 14, weight: .semibold))
        }
        .buttonStyle(OrbitFlatButtonStyle(variant: .primary, size: .md, isIconOnly: true))
        .disabled(!canSend)
        .keyboardShortcut(.return, modifiers: .command)
        .help(sendHelp)
    }

    private var sendHelp: String {
        if model.canUseAIChat {
            switch model.aiMode {
            case .cloud: return "Send message via Cloud AI"
            case .local: return "Send message via local Ollama model"
            case .byok: return "Send message via your API key"
            case nil: return "Send message (AI or keyword fallback)"
            }
        }
        return "Search saved context"
    }

    private var spinOffButton: some View {
        Button(action: spinOffChat) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.body)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
        }
        .buttonStyle(OrbitFlatButtonStyle(variant: .ghost, size: .md, isIconOnly: true))
        .help("Pop out chat")
    }

    @Environment(\.openWindow) private var openWindow
    @AppStorage("chatIsFloating") private var chatIsFloating = false

    private var canSend: Bool {
        !model.chatStore.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.chatStore.isStreaming
            && (model.canUseLiveServices || model.canSearchLocally)
    }

    private func sendMessage() {
        guard canSend else { return }
        Task {
            await model.chatStore.send(
                canUseLiveServices: model.canUseLiveServices,
                canSearchLocally: model.canSearchLocally,
                hasDatabase: model.canBrowseContext
            )
        }
    }

    private func spinOffChat() {
        chatIsFloating = true
        openWindow(id: "floating-chat")
    }
}
