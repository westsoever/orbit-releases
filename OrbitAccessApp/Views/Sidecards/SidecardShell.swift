import SwiftUI

/// The elevated card shell every sidecard widget renders inside: a header row
/// (chevron + title + optional subtitle) that toggles collapse, plus the
/// widget's own content below when expanded.
struct SidecardShell<Content: View>: View {
    let widget: SidecardWidget
    let subtitle: String?
    let isCollapsed: Bool
    let onToggleCollapse: () -> Void
    @ViewBuilder var content: () -> Content

    @Environment(AppViewModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    private var isEditing: Bool { model.sidecardStore.isEditing }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !isCollapsed {
                content()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .animation(OrbitMotion.collapse, value: isCollapsed)
        .orbitOverlayChrome(cornerRadius: OrbitShape.radiusSidecard, colorScheme: colorScheme)
    }

    /// Split so the hover highlight (fill + cursor) is fully suppressed while
    /// editing, not just the cursor push/pop — the drag handle owns the
    /// gesture in edit mode and must not fight a hover fill underneath it.
    @ViewBuilder
    private var header: some View {
        if isEditing {
            headerRow
        } else {
            headerRow.orbitHoverRow(cornerRadius: OrbitShape.radiusSidecard)
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            if isEditing {
                Image(systemName: "line.3.horizontal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .animation(OrbitMotion.collapse, value: isCollapsed)
            }

            Text(widget.title)
                .font(.callout.weight(.semibold))
                .kerning(-0.1)

            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                    .opacity(isEditing ? 0.5 : 1)
            }

            Spacer(minLength: 0)

            if isEditing {
                OrbitIconButton(label: "Hide widget", systemImage: "minus.circle", variant: .ghost, size: .sm) {
                    model.sidecardStore.toggleVisibility(widget)
                }
            }
        }
        .padding(12)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isEditing else { return }
            onToggleCollapse()
        }
        .help(isEditing ? "" : (isCollapsed ? "Expand" : "Collapse"))
    }
}
