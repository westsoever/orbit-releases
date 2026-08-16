import Foundation
import Observation
import Combine

@Observable
final class ChatStore {
    var messages: [ChatMessage] = []
    var inputText = ""
    var isStreaming = false
    var errorMessage: String?
    var focusRequested = false

    /// Archived conversations, newest first. `messages` above stays the live conversation.
    var history: [ChatConversation] = []
    var activeConversationID = UUID()

    @ObservationIgnored private var bridge: OrbitBridgeProtocol?

    /// Model override attached to the *next* send only (Plan 27 Phase 4).
    ///
    /// A routine prefills the input box and the user presses send later, so the
    /// routine's model choice has to survive that gap. It is set by
    /// `prefillInput(_:model:)`, consumed by the next non-empty `send(...)`, and
    /// cleared on consumption — otherwise a routine's model would silently leak
    /// into every later message the user types. It is also cleared whenever the
    /// input box is reset (new/opened conversation) or re-prefilled without a model.
    @ObservationIgnored private var pendingModelOverride: String?

    func configure(bridge: OrbitBridgeProtocol) {
        self.bridge = bridge
    }

    /// Replace the input box contents. `model` (nil = app default) applies to the
    /// next send only; passing nil also clears any previously pending override.
    func prefillInput(_ text: String, model: String? = nil) {
        inputText = text
        pendingModelOverride = Self.normalisedModel(model)
    }

    /// Returns the pending override and clears it, so it is honoured exactly once.
    private func consumePendingModelOverride() -> String? {
        defer { pendingModelOverride = nil }
        return pendingModelOverride
    }

    private static func normalisedModel(_ model: String?) -> String? {
        guard let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    func requestFocus() {
        focusRequested = true
    }

    func clearFocusRequest() {
        focusRequested = false
    }

    // MARK: - Conversations

    @MainActor
    func loadHistory() {
        history = ChatHistoryStorage.load()
    }

    /// Upper bound on messages kept in the *live* conversation before the oldest ones are
    /// rolled over into their own archived conversation (plan 52 Phase 3).
    ///
    /// `ChatHistoryStorage.historyLimit` caps how many conversations are stored; it says nothing
    /// about how long one conversation may get, and an unbounded live array is re-snapshotted and
    /// re-encoded on every turn. 400 is deliberately generous: it is far past any orchestrator
    /// context window, so it never truncates a conversation the model could still see in full.
    static let liveMessageLimit = 400

    /// How many of the newest messages stay in the live conversation after a rollover. The gap
    /// against `liveMessageLimit` is what makes rollover amortised — 100 turns of headroom rather
    /// than a rollover on every message once the cap is reached.
    ///
    /// **Invariant: `liveMessageRetained < liveMessageLimit`.** `rollOverOverflowIfNeeded()`
    /// clamps the split so violating it degrades to "rollover never fires" instead of trapping,
    /// but a value at or above the limit still makes this cap a silent no-op — keep the gap.
    static let liveMessageRetained = 300

    /// The one archive conversation holding everything rolled out of the current live
    /// conversation. One per live conversation, reused across rollovers — a fresh archive per
    /// rollover would spend a slot of `ChatHistoryStorage.historyLimit` every 100 turns and
    /// eventually evict the user's *other* conversations, turning a cap into silent deletion.
    ///
    /// While set, `syncActiveToHistory()` re-stamps this archive's `updatedAt` in lockstep with
    /// the live conversation, so the pure-LRU `ChatHistoryStorage.trimmed(_:)` can never evict an
    /// archive whose owner is still in active use.
    @ObservationIgnored private var activeArchiveID: UUID?

    /// The archive is stamped this much *older* than its owner on every sync, so the History menu
    /// lists it immediately below the conversation it belongs to. Identical timestamps would leave
    /// the order up to Swift's (unstable) sort.
    private static let archiveStampOffset: TimeInterval = -0.001

    /// Move the oldest messages out of an over-long live conversation into its archive
    /// conversation, and leave a visible marker behind.
    ///
    /// Nothing is deleted: the overflow stays readable as a real entry in the History menu, and
    /// the live conversation gains a `.system` message naming where those messages went (the
    /// chat bubble renders any non-`.user` role, so it is visible, not a hidden flag). Silently
    /// dropping them would be a worse bug than the cost this cap exists to avoid.
    @MainActor
    private func rollOverOverflowIfNeeded() {
        guard messages.count > Self.liveMessageLimit else { return }
        // Clamped: `Array.prefix(_:)` traps on a negative length, so a future tuning pass that
        // set `liveMessageRetained >= liveMessageLimit` would kill the app from the very code
        // added to make long sessions survivable. Clamping degrades to a no-op instead.
        let retainCount = min(Self.liveMessageRetained, messages.count)
        let overflowCount = messages.count - retainCount
        guard overflowCount > 0 else { return }

        // Rollover notices are app-generated pointers, not conversation content. Archiving them
        // would make each archive accumulate stale self-references ("… were moved to X") sitting
        // between real messages, so they are dropped at the boundary rather than carried in.
        let overflow = messages.prefix(overflowCount).filter { $0.role != .system }
        let retained = Array(messages.suffix(retainCount))

        let archiveTitle: String
        if let archiveID = activeArchiveID,
           let index = history.firstIndex(where: { $0.id == archiveID }) {
            history[index].messages.append(contentsOf: overflow)
            // Reuse keeps the archive's original title. Recomputing it from the live messages
            // would name the *current* first user message — which was archived at the previous
            // rollover — so the notice below would point at a History entry that does not exist
            // under that name. `updatedAt` is stamped by `syncActiveToHistory()`, which is this
            // method's only caller, so it is deliberately not stamped twice here.
            archiveTitle = history[index].title
        } else {
            // Titled from what the archive actually holds, not from the live conversation.
            archiveTitle = "\(ChatConversation.title(from: overflow)) (earlier)"
            let archive = ChatConversation(title: archiveTitle, messages: overflow)
            activeArchiveID = archive.id
            history.append(archive)
        }

        let archivedCount = history.first { $0.id == activeArchiveID }?.messages.count ?? overflow.count
        let notice = ChatMessage(
            role: .system,
            content: """
            The \(archivedCount) earliest messages in this conversation were moved to \
            “\(archiveTitle)” in History to keep this one fast. Nothing was deleted — open that \
            conversation to read them.
            """
        )
        messages = [notice] + retained
    }

    /// Snapshot the live conversation into `history` and persist. No-op while empty.
    ///
    /// The persist step is queued, not synchronous — see `ChatHistoryStorage.scheduleSave(_:)`.
    @MainActor
    func syncActiveToHistory() {
        guard !messages.isEmpty else { return }
        rollOverOverflowIfNeeded()
        let now = Date()
        // The rolling archive is an ordinary conversation to `ChatHistoryStorage.trimmed(_:)`,
        // which is a pure LRU on `updatedAt`. Stamping it only at rollover time would let it age
        // past the 50-slot boundary while its owner — re-stamped every turn below — stayed
        // permanently fresh: hundreds of real user messages silently deleted, with the live
        // conversation still showing a notice pointing at a History entry that no longer exists.
        // Stamping both from the same instant makes the archive outlive everything its owner does.
        if let archiveID = activeArchiveID,
           let archiveIndex = history.firstIndex(where: { $0.id == archiveID }) {
            history[archiveIndex].updatedAt = now.addingTimeInterval(Self.archiveStampOffset)
        }
        let title = ChatConversation.title(from: messages)
        if let index = history.firstIndex(where: { $0.id == activeConversationID }) {
            history[index].title = title
            history[index].messages = messages
            history[index].updatedAt = now
        } else {
            history.append(
                ChatConversation(
                    id: activeConversationID,
                    title: title,
                    messages: messages,
                    updatedAt: now
                )
            )
        }
        // Trim in memory too, so the History menu matches what is on disk. The active
        // conversation was just stamped with `Date()`, so it is always newest and safe.
        history = ChatHistoryStorage.trimmed(history)
        ChatHistoryStorage.scheduleSave(history)
    }

    /// Archive the current conversation and reset the pane to its landing state.
    @MainActor
    func newConversation() {
        guard !isStreaming else { return }
        syncActiveToHistory()
        // Durability checkpoint: the queued write holds a value snapshot so it is already safe
        // from the mutations below, but leaving a conversation is a natural point to make sure
        // it is really on disk rather than in flight.
        ChatHistoryStorage.flushPendingSaves()
        messages = []
        inputText = ""
        pendingModelOverride = nil
        errorMessage = nil
        activeConversationID = UUID()
        activeArchiveID = nil
    }

    @MainActor
    func openConversation(id: UUID) {
        guard !isStreaming, id != activeConversationID else { return }
        guard history.contains(where: { $0.id == id }) else { return }
        // Archive first, then re-read: syncActiveToHistory() mutates `history`.
        syncActiveToHistory()
        ChatHistoryStorage.flushPendingSaves()
        guard let conversation = history.first(where: { $0.id == id }) else { return }
        messages = conversation.messages
        activeConversationID = id
        // The archive belongs to the conversation being left, not the one being opened.
        activeArchiveID = nil
        inputText = ""
        pendingModelOverride = nil
        errorMessage = nil
    }

    @MainActor
    func send(canUseLiveServices: Bool, canSearchLocally: Bool, hasDatabase: Bool) async {
        let query = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Consume only once we know a real send is happening — an empty box must
        // not burn a routine's pending override.
        guard !query.isEmpty else { return }
        let modelOverride = consumePendingModelOverride()

        TelemetryService.shared.track(
            "chat_sent",
            properties: ["mode": canUseLiveServices ? "bridge" : "offline"]
        )

        if canUseLiveServices, let bridge {
            await sendViaBridge(
                bridge: bridge,
                query: query,
                model: modelOverride,
                fallbackOffline: canSearchLocally
            )
        } else if canSearchLocally, let bridge {
            await sendKeywordOnly(query: query, bridge: bridge)
        } else {
            errorMessage = ChatErrorFormatter.noChatAvailable(
                hasDatabase: hasDatabase,
                hasDaemon: canUseLiveServices
            )
        }
    }

    @MainActor
    private func sendViaBridge(
        bridge: OrbitBridgeProtocol,
        query: String,
        model: String?,
        fallbackOffline: Bool
    ) async {
        errorMessage = nil
        inputText = ""
        messages.append(ChatMessage(role: .user, content: query))
        isStreaming = true
        var assistant = ChatMessage(role: .assistant, content: "")
        messages.append(assistant)
        let assistantID = assistant.id

        do {
            for try await chunk in bridge.chatStream(query, model: model) {
                switch chunk.kind {
                case .text(let delta):
                    assistant.content += delta
                    replaceMessage(id: assistantID, with: assistant)
                case .sources(let hits):
                    assistant.sourceAtoms = hits
                    replaceMessage(id: assistantID, with: assistant)
                case .done:
                    TelemetryService.shared.track("chat_completed")
                }
            }
            if assistant.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                removeMessage(id: assistantID)
                errorMessage = "orbit did not return an answer. Check your AI setup and try again."
            }
        } catch {
            removeMessage(id: assistantID)
            TelemetryService.shared.track(
                "chat_failed",
                properties: ["kind": Self.errorKind(error)]
            )
            if fallbackOffline, ChatErrorFormatter.isMissingCredentials(error) {
                await sendKeywordOnly(
                    query: query,
                    bridge: bridge,
                    includeUserMessage: false,
                    preamble: "AI is not configured yet — showing keyword matches from your saved context instead."
                )
            } else {
                errorMessage = ChatErrorFormatter.userMessage(for: error)
            }
        }
        isStreaming = false
        syncActiveToHistory()
    }

    /// Coarse, fixed-enum error category for telemetry only — never the formatted
    /// message itself, which might embed request/response content.
    private static func errorKind(_ error: Error) -> String {
        if ChatErrorFormatter.isMissingCredentials(error) {
            return "missing_credentials"
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "timeout"
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost:
                return "network"
            default:
                return "url_error"
            }
        }
        return "other"
    }

    /// Keyword-only answer: retrieval without a completion.
    ///
    /// This used to be the *offline* path — a direct FTS query through GRDB while the daemon
    /// was down. Plan 51 decision D1 removed the app's database handle, so the search now goes
    /// to `GET /api/search`, which is the same FTS query run by the process that holds the
    /// SQLCipher key. It still serves its real purpose: answering from captured context when
    /// **AI** is unconfigured, which is the only branch that reaches here in practice.
    @MainActor
    private func sendKeywordOnly(
        query: String,
        bridge: OrbitBridgeProtocol,
        includeUserMessage: Bool = true,
        preamble: String? = nil
    ) async {
        errorMessage = nil
        if includeUserMessage {
            inputText = ""
            messages.append(ChatMessage(role: .user, content: query))
        }
        isStreaming = true

        // `search` swallows its own transport errors and returns [] — the empty-result copy
        // below already covers that case, so there is nothing to catch here.
        let hits = await bridge.search(query, limit: 8)
        TelemetryService.shared.track(
            "search_performed",
            properties: ["result_count": hits.count]
        )

        let body: String
        if hits.isEmpty {
            body = "No matching context found in your local history. Capture new activity by using your Mac as usual, or try different keywords."
        } else {
            body = formatOfflineContext(hits)
                + "\n\n_(Keyword matches only. Configure Cloud AI or a local Ollama model above for full answers.)_"
        }
        let content = [preamble, body].compactMap { $0 }.joined(separator: "\n\n")
        let assistant = ChatMessage(role: .assistant, content: content, sourceAtoms: hits)
        messages.append(assistant)
        isStreaming = false
        syncActiveToHistory()
    }

    /// Context format copied from orbit/browser_bridge/server.py _build_chat_context
    private func formatOfflineContext(_ hits: [SearchHit]) -> String {
        hits.enumerated().map { index, hit in
            "[\(index + 1)] \(hit.appName) — \(hit.windowTitle ?? "untitled")\n\(hit.snippetHtml)"
        }.joined(separator: "\n\n")
    }

    private func replaceMessage(id: UUID, with message: ChatMessage) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index] = message
    }

    private func removeMessage(id: UUID) {
        messages.removeAll { $0.id == id }
    }
}
