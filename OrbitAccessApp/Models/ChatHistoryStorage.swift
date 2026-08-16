import Foundation

/// Conversation history persistence.
///
/// Storage shape copied from `RoutineStorage` (Models/RoutineStorage.swift): a JSON file
/// in `~/.orbit`, atomic write, graceful fallback when absent or undecodable.
///
/// History deliberately does NOT live in `~/.orbit/orbit.db`: that store is SQLCipher-encrypted
/// and the Python daemon owns both its key and its schema (plan 51 decision D1), so this app
/// cannot write to it at all.
///
/// **Writes are asynchronous and coalescing** (plan 52 Phase 3). `ChatStore.syncActiveToHistory()`
/// runs on the main actor after every chat turn, and it used to call `save(_:)` directly — a full
/// `JSONEncoder` pass over *every* stored conversation plus an atomic whole-file write, on the
/// main thread, once per turn, with the active conversation only ever growing. `scheduleSave(_:)`
/// hands a value snapshot to a serial background queue instead, so the main actor pays only the
/// snapshot cost, and bursts of turns collapse into a single encode+write.
enum ChatHistoryStorage {
    /// Upper bound on stored conversations, keeping the JSON file small.
    static let historyLimit = 50

    private static var fileURL: URL {
        OrbitPaths.orbitDirectory.appendingPathComponent("chat-history.json")
    }

    // MARK: - Async write plumbing

    /// Serial: two overlapping writes to the same file would race even with `.atomic`.
    /// `.userInitiated` rather than `.utility` deliberately — every scheduled write follows a
    /// user action, and a low-QoS queue could sit unscheduled long enough to widen the
    /// unsaved-turn window that `flushPendingSaves()` exists to keep narrow.
    private static let writeQueue = DispatchQueue(
        label: "com.orbit.access.chat-history-write",
        qos: .userInitiated
    )

    /// Latest-wins snapshot handed off to `writeQueue`. Guarded by `pendingLock` because it is
    /// written from the main actor and read on `writeQueue`.
    private static let pendingLock = NSLock()
    private static var pending: [ChatConversation]?

    /// Newest first, capped at `historyLimit`. Applied on load, on save, and to the
    /// in-memory list so the History menu never offers conversations that would not
    /// survive a restart.
    static func trimmed(_ conversations: [ChatConversation]) -> [ChatConversation] {
        Array(
            conversations
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(historyLimit)
        )
    }

    static func load() -> [ChatConversation] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ChatConversation].self, from: data) else {
            return []
        }
        return trimmed(decoded)
    }

    /// Queue `conversations` for persistence and return immediately.
    ///
    /// Coalescing is latest-wins: each call replaces the pending snapshot and enqueues one
    /// drain block. Because the queue is serial, a burst of turns produces at most one encode
    /// per drained snapshot and the surplus blocks find nothing to do. Durability window is
    /// therefore "one dispatch hop plus one encode+write", not "until a timer fires" — there is
    /// deliberately no debounce delay here, because a delay would trade this phase's perf bug
    /// for a data-loss bug.
    static func scheduleSave(_ conversations: [ChatConversation]) {
        pendingLock.lock()
        pending = conversations
        pendingLock.unlock()
        writeQueue.async { drainPending() }
    }

    /// Block until nothing is queued. Call at durability checkpoints — switching or starting a
    /// conversation (`ChatStore`), and app termination (`AppDelegate.applicationWillTerminate`) —
    /// so an in-flight snapshot cannot be lost. Costs one synchronous encode+write, i.e. exactly
    /// what the old per-turn path cost, but only at those checkpoints instead of on every turn.
    ///
    /// The `applicationWillTerminate` call site covers every exit path: `NSApplication`
    /// auto-registers its delegate for `willTerminateNotification`, and the ⌘Q /
    /// `applicationShouldTerminate` → `.terminateLater` route resumes through
    /// `NSApp.reply(toApplicationShouldTerminate: true)`, which posts that same notification.
    static func flushPendingSaves() {
        writeQueue.sync { drainPending() }
    }

    private static func drainPending() {
        pendingLock.lock()
        let next = pending
        pending = nil
        pendingLock.unlock()
        // nil means an earlier block on this serial queue already wrote this snapshot.
        guard let next else { return }
        save(next)
    }

    /// Synchronous whole-file write. Prefer `scheduleSave(_:)` from the main actor.
    static func save(_ conversations: [ChatConversation]) {
        try? OrbitPaths.ensureOrbitDirectoryExists()
        if let data = try? JSONEncoder().encode(trimmed(conversations)) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
