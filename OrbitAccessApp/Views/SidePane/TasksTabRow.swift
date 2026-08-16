import SwiftUI

/// Sidebane nav row that swaps the center pane between chat and the Kanban board
/// (`MainWindowView`'s `mainContentMode`). Shape copied from `AgentShortcutRow`
/// (icon + label + Spacer + reserved affordance width, `orbitHoverRow`, plain
/// button style), plus two things no other Sidebane row needs: a persistent
/// selected-state tint (this is the app's first and only persistent nav
/// selection — every other row is fire-and-forget) and a pending-count badge.
///
/// `@AppStorage("mainContentMode")` mirrors `MainWindowView`'s binding by key
/// string, the same cross-view sharing pattern `ChatInputBar`/`MainChatView`
/// already use for `chatIsFloating`/`insightVisible` — this view does not read
/// or write `MainWindowView` directly.
struct TasksTabRow: View {
    @Environment(AppViewModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("mainContentMode") private var mainContentMode: MainContentMode = .chat

    private var isSelected: Bool { mainContentMode == .tasks }
    private var pendingCount: Int { model.taskStore.pendingTasks.count }

    var body: some View {
        Button {
            model.commitSidecardEditIfLeavingChat(from: mainContentMode)
            mainContentMode = isSelected ? .chat : .tasks
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.body)
                    .foregroundStyle(isSelected ? Color.orbitAccent(for: colorScheme) : Color.primary)
                    .frame(width: 20)
                Text("Tasks")
                    .font(.callout)
                    .foregroundStyle(isSelected ? Color.orbitAccent(for: colorScheme) : .primary)
                    .kerning(-0.1)
                Spacer(minLength: 0)
                if pendingCount > 0 {
                    Text("\(pendingCount)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orbitAccent(for: colorScheme), in: Capsule())
                }
                Color.clear
                    .frame(width: SidebaneMetrics.menuAffordanceWidth)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                isSelected ? Color.orbitAccent(for: colorScheme).opacity(0.12) : Color.orbitSurfaceMuted(for: colorScheme),
                in: RoundedRectangle(cornerRadius: OrbitShape.radiusControl)
            )
            .orbitHoverRow(tint: Color.orbitAccent(for: colorScheme))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
