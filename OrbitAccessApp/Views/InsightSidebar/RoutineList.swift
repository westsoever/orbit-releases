import SwiftUI

struct RoutineList: View {
    @Environment(AppViewModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    /// Touch statusTick so badges refresh on the 30s poll.
    private var now: Date { model.insightStore.statusTick }
    /// Widget shows only routines scheduled today — a weekly routine on an off day,
    /// or a monthly routine on the wrong date, is not "due" and should not appear.
    private var routines: [RoutineBlock] {
        model.insightStore.routines.filter { $0.isScheduledToday(now: now) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if routines.isEmpty {
                Text("No routines configured")
                    .font(.caption)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                ForEach(routines) { routine in
                    routineRow(routine)
                }
            }

            // Honest status: schedules are display-only until a scheduler exists (Plan 27).
            Text("Routines do not run on a schedule by themselves yet — badges just show what's due; use Prepare in chat or Mark done today to complete one.")
                .font(.caption2)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                .fixedSize(horizontal: false, vertical: true)

            if let error = model.insightStore.routineErrorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(Color.orbitScoreRed)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button("Add routine") {
                model.beginCreateRoutine()
            }
            .buttonStyle(OrbitFlatButtonStyle(variant: .secondary))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func routineRow(_ routine: RoutineBlock) -> some View {
        let done = routine.isCompletedToday(now: now)

        return SidecardRow {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(routine.title.isEmpty ? "Untitled routine" : routine.title)
                        .font(.callout.weight(.medium))
                        .kerning(-0.1)
                        .lineLimit(1)
                    Text(routine.scheduleSummary)
                        .font(.caption2)
                        .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                statusBadge(routine: routine, done: done, running: routine.runState == .running)
            }
        }
        .orbitHoverRow(cornerRadius: OrbitShape.radiusChip)
        .contentShape(Rectangle())
        .onTapGesture {
            guard routine.runState != .running else { return }
            model.beginEditRoutine(routine)
        }
        .help(routine.runState == .running ? "Preparing in chat" : "Edit routine")
        .contextMenu {
            Button("Edit…") {
                model.beginEditRoutine(routine)
            }
            Button("Mark done today") {
                model.insightStore.markCompleted(id: routine.id)
                model.insightStore.routineErrorMessage = nil
            }
            .disabled(done)
            Button(routine.runState == .running ? "Preparing…" : "Prepare in chat") {
                Task { await model.runRoutine(id: routine.id) }
            }
            .disabled(routine.runState == .running)
        }
    }

    @ViewBuilder
    private func statusBadge(routine: RoutineBlock, done: Bool, running: Bool) -> some View {
        // Preparing wins over both. Otherwise: green once real evidence (lastCompletedAt
        // today) says it ran; yellow for the rest of today's scheduled window — including
        // after the fire time has passed with no run, since there is no third "missed"
        // state (honest ladder: no scheduler exists yet, see the disclaimer below).
        if running {
            Label("Preparing", systemImage: "circle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.orbitAccent(for: colorScheme))
                .labelStyle(.titleAndIcon)
                .imageScale(.small)
        } else if done {
            Label("Ran today", systemImage: "checkmark.circle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.orbitScoreEmerald)
                .labelStyle(.titleAndIcon)
                .imageScale(.small)
        } else {
            Label(
                "Due \(RoutineSchedule.displayTime(routine.time, now: now))",
                systemImage: "circle.fill"
            )
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.orbitScoreAmber)
            .labelStyle(.titleAndIcon)
            .imageScale(.small)
        }
    }
}
