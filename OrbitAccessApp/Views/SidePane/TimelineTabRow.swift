import SwiftUI

/// Sidebane nav row that swaps the center pane to the Timeline view (Plan 17 Phase 6.2).
/// Copied from `TasksTabRow.swift` — icon + label + persistent selected-state tint,
/// `orbitHoverRow`, plain button style — minus the pending-count badge: Timeline has no
/// natural pending-count analog.
struct TimelineTabRow: View {
    @Environment(AppViewModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("mainContentMode") private var mainContentMode: MainContentMode = .chat

    private var isSelected: Bool { mainContentMode == .timeline }

    var body: some View {
        Button {
            model.commitSidecardEditIfLeavingChat(from: mainContentMode)
            mainContentMode = isSelected ? .chat : .timeline
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "calendar.day.timeline.left")
                    .font(.body)
                    .foregroundStyle(isSelected ? Color.orbitAccent(for: colorScheme) : Color.primary)
                    .frame(width: 20)
                Text("Timeline")
                    .font(.callout)
                    .foregroundStyle(isSelected ? Color.orbitAccent(for: colorScheme) : .primary)
                    .kerning(-0.1)
                Spacer(minLength: 0)
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
