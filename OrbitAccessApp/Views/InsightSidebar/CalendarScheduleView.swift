import SwiftUI

struct CalendarScheduleView: View {
    var events: [CalendarEvent] = []
    var isConnected: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if !isConnected {
            disconnectedPlaceholder
        } else if events.isEmpty {
            emptyDayPlaceholder
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(events) { event in
                    timelineRow(event)
                }
            }
        }
    }

    private var disconnectedPlaceholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "calendar")
                .font(.title3)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
            Text("No calendar connected")
                .font(.caption)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var emptyDayPlaceholder: some View {
        Text("Nothing scheduled today")
            .font(.caption)
            .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
    }

    private func timelineRow(_ event: CalendarEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Circle()
                    .fill(Color.orbitAccent(for: colorScheme))
                    .frame(width: 8, height: 8)
                Rectangle()
                    .fill(Color.orbitTrack(for: colorScheme))
                    .frame(width: 1)
            }
            .frame(width: 8)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    TimeChip(time: formatTime(event.start))
                    Text(event.title)
                        .font(.callout.weight(.medium))
                        .kerning(-0.1)
                }
                Text("\(formatTime(event.start)) – \(formatTime(event.end))")
                    .font(.caption2)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
            }
            .padding(.bottom, 12)
        }
    }

    private func formatTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
