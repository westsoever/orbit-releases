import SwiftUI

struct ContextSourceChip: View {
    @Environment(\.colorScheme) private var colorScheme
    let atom: SearchHit
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: "doc.text")
                    .font(.caption2)
                Text(chipLabel)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .foregroundStyle(Color.orbitAccent(for: colorScheme))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.orbitSurfaceMuted(for: colorScheme), in: RoundedRectangle(cornerRadius: OrbitShape.radiusChip))
            .orbitHoverRow(cornerRadius: OrbitShape.radiusChip, tint: .orbitAccent(for: colorScheme))
        }
        .buttonStyle(.plain)
    }

    private var chipLabel: String {
        let app = atom.appName.isEmpty ? "Unknown" : atom.appName
        if let title = atom.windowTitle, !title.isEmpty {
            return "\(app) · \(title)"
        }
        return app
    }
}
