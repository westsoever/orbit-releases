import Foundation
import Observation
import SwiftUI

@Observable
final class SidecardStore {
    private(set) var layout: [SidecardLayoutEntry] = []
    /// Mutate only via `setEditing` / begin / commit / discard — never assign directly.
    private(set) var isEditing: Bool = false

    /// Pre-edit layout captured by `beginEditing()`; restored by `discardEditing()`.
    @ObservationIgnored private var layoutSnapshot: [SidecardLayoutEntry]?

    var visibleWidgets: [SidecardLayoutEntry] {
        layout.filter(\.isVisible)
    }

    func load() {
        layout = SidecardLayoutStorage.load()
    }

    /// Enter edit mode, snapshotting the current layout for a later discard.
    func beginEditing() {
        layoutSnapshot = layout
        setEditing(true)
    }

    /// Leave edit mode keeping the eagerly-persisted layout. Clears the snapshot only.
    func commitEditing() {
        layoutSnapshot = nil
        setEditing(false)
    }

    /// Restore the pre-edit layout (and rewrite disk), then leave edit mode.
    /// No-op if there is no snapshot (e.g. `beginEditing()` was never called).
    func discardEditing() {
        guard let snapshot = layoutSnapshot else { return }
        layout = snapshot
        SidecardLayoutStorage.save(layout)
        layoutSnapshot = nil
        setEditing(false)
    }

    /// Flip `isEditing` without implicit animations (avoids AppKit window-size abort).
    private func setEditing(_ editing: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isEditing = editing
        }
    }

    /// Index-based reorder. No-op if either widget is not present in the layout.
    func move(from: SidecardWidget, to: SidecardWidget) {
        guard let sourceIndex = layout.firstIndex(where: { $0.widget == from }),
              let destinationIndex = layout.firstIndex(where: { $0.widget == to }) else {
            return
        }
        guard sourceIndex != destinationIndex else { return }
        let entry = layout.remove(at: sourceIndex)
        // Removing an earlier element shifts every later index down by one.
        let insertIndex = sourceIndex < destinationIndex ? destinationIndex - 1 : destinationIndex
        layout.insert(entry, at: insertIndex)
        SidecardLayoutStorage.save(layout)
    }

    func toggleVisibility(_ widget: SidecardWidget) {
        guard let index = layout.firstIndex(where: { $0.widget == widget }) else { return }
        layout[index].isVisible.toggle()
        SidecardLayoutStorage.save(layout)
    }

    func toggleCollapsed(_ widget: SidecardWidget) {
        guard let index = layout.firstIndex(where: { $0.widget == widget }) else { return }
        layout[index].isCollapsed.toggle()
        SidecardLayoutStorage.save(layout)
    }

    func resetToDefaults() {
        layout = SidecardLayoutStorage.resetToDefaults()
    }
}
