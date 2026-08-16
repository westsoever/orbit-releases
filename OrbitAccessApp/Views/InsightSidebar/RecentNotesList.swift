import SwiftUI

struct RecentNotesList: View {
    let notes: [SearchHit]
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedAtom: SearchHit?

    var body: some View {
        Group {
            if notes.isEmpty {
                Text("No recent notes")
                    .font(.caption)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 6) {
                    ForEach(notes) { note in
                        noteRow(note)
                    }
                }
            }
        }
        .sheet(item: $selectedAtom) { atom in
            ContextAtomDetailSheet(atom: atom)
        }
    }

    private func noteRow(_ note: SearchHit) -> some View {
        Button {
            selectedAtom = note
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(stripHTML(note.snippetHtml))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text("\(note.appName.isEmpty ? "Unknown" : note.appName) · \(formatTimestamp(note.timestamp))")
                    .font(.caption2)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .orbitHoverRow(cornerRadius: OrbitShape.radiusChip)
        }
        .buttonStyle(.plain)
        .help(stripHTML(note.snippetHtml))
    }

    private func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    private func formatTimestamp(_ timestamp: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: timestamp) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: timestamp) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return String(timestamp.suffix(8))
    }
}
