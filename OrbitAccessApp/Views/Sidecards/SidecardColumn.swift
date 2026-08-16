import SwiftUI

/// Renders the ordered, visible sidecard widgets from `model.sidecardStore`.
struct SidecardColumn: View {
    @Environment(AppViewModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @State private var dropTargetID: SidecardWidget?

    private var isEditing: Bool { model.sidecardStore.isEditing }

    var body: some View {
        VStack(alignment: .leading, spacing: SidecardMetrics.cardSpacing) {
            ForEach(model.sidecardStore.visibleWidgets) { entry in
                cardRow(for: entry)
            }

            if isEditing {
                hiddenWidgetTray
            }
        }
    }

    @ViewBuilder
    private func cardRow(for entry: SidecardLayoutEntry) -> some View {
        VStack(spacing: 0) {
            if dropTargetID == entry.widget {
                RoundedRectangle(cornerRadius: OrbitShape.radiusChip)
                    .fill(Color.orbitAccent(for: colorScheme))
                    .frame(height: 2)
                    .padding(.bottom, 8)
            }

            let shell = SidecardShell(
                widget: entry.widget,
                subtitle: subtitle(for: entry.widget),
                isCollapsed: entry.isCollapsed,
                onToggleCollapse: { model.sidecardStore.toggleCollapsed(entry.widget) }
            ) {
                content(for: entry.widget)
            }
            // Reserve horizontal render room for overlay shadow without shrinking card width.
            let presentedShell = shell
                .frame(width: SidecardMetrics.columnWidth, alignment: .leading)
                .padding(.horizontal, SidecardMetrics.shadowHorizontalInset)
                .padding(.horizontal, -SidecardMetrics.shadowHorizontalInset)

            if isEditing {
                presentedShell
                    .draggable(entry.widget.rawValue)
                    .dropDestination(for: String.self) { items, _ in
                        guard let raw = items.first,
                              let source = SidecardWidget(rawValue: raw) else { return false }
                        withAnimation(OrbitMotion.collapse) {
                            model.sidecardStore.move(from: source, to: entry.widget)
                        }
                        return true
                    } isTargeted: { targeted in
                        dropTargetID = targeted ? entry.widget : nil
                    }
            } else {
                presentedShell
            }
        }
    }

    @ViewBuilder
    private var hiddenWidgetTray: some View {
        let hidden = model.sidecardStore.layout.filter { !$0.isVisible }
        if !hidden.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Hidden")
                    .font(.caption)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))

                FlowLayout(spacing: 8) {
                    ForEach(hidden) { entry in
                        hiddenWidgetChip(for: entry)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private func hiddenWidgetChip(for entry: SidecardLayoutEntry) -> some View {
        HStack(spacing: 6) {
            Text(entry.widget.title)
                .font(.caption)
            OrbitIconButton(label: "Show widget", systemImage: "plus.circle", variant: .ghost, size: .sm) {
                model.sidecardStore.toggleVisibility(entry.widget)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Color.orbitSurfaceMuted(for: colorScheme),
            in: RoundedRectangle(cornerRadius: OrbitShape.radiusChip)
        )
        .orbitHoverRow(cornerRadius: OrbitShape.radiusChip)
    }

    @ViewBuilder
    private func content(for widget: SidecardWidget) -> some View {
        switch widget {
        case .todaySummary:
            TodaySummaryCard()
        case .recommendedTasks:
            TaskCardList()
        case .todaysSchedule:
            CalendarScheduleView(
                events: model.insightStore.calendarEvents,
                isConnected: model.insightStore.isCalendarConnected
            )
        case .routines:
            RoutineList()
        case .contextStream:
            RecentNotesList(notes: model.insightStore.recentNotes)
        }
    }

    private func subtitle(for widget: SidecardWidget) -> String? {
        switch widget {
        case .todaySummary:
            if let day = model.insightStore.digestDay { return day }
            let count = model.insightStore.digestSessionCount
            return count > 0 ? "\(count) sessions" : nil
        case .recommendedTasks:
            // A detect run is the one thing worth saying in the header instead of a count.
            if model.taskStore.detectPhase == .running { return "Suggesting…" }
            let count = model.taskStore.pendingTasks.count + model.taskStore.artifacts.count
            return "\(count) tasks"
        case .todaysSchedule:
            let count = model.insightStore.calendarEvents.count
            return "\(count) upcoming"
        case .routines:
            let count = model.insightStore.routines.count
            return "\(count) today"
        case .contextStream:
            return nil
        }
    }
}
