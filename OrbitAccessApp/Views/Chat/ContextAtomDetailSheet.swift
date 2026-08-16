import SwiftUI

struct ContextAtomDetailSheet: View {
    let atom: SearchHit
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            metadata
            OrbitHairlineDivider()
            atomContent
            Spacer()
            footer
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 320)
        .background(Color.orbitCanvas(for: colorScheme))
    }

    private var header: some View {
        HStack {
            Text(atom.windowTitle ?? atom.appName)
                .font(.headline)
                .kerning(-0.1)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.escape)
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            metadataRow(label: "App", value: atom.appName)
            metadataRow(label: "Role", value: atom.role)
            if let label = atom.label {
                metadataRow(label: "Label", value: label)
            }
            metadataRow(label: "Captured", value: atom.timestamp)
            metadataRow(label: "Score", value: String(format: "%.2f", atom.score))
        }
    }

    private func metadataRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
        }
    }

    private var atomContent: some View {
        ScrollView {
            Text(stripHTML(atom.snippetHtml))
                .font(.callout)
                .kerning(-0.1)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack {
            Text("Event #\(atom.eventId)")
                .font(.caption2)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
            Spacer()
            Button("Open Source Event") {
                openEventURI()
            }
            .disabled(atom.eventUri.isEmpty)
        }
    }

    private func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    private func openEventURI() {
        guard let url = URL(string: atom.eventUri) else { return }
        NSWorkspace.shared.open(url)
    }
}
