import SwiftUI

/// Non-interactive capture summary row — chrome matched to AgentShortcutRow.
struct SidebaneCaptureFooter: View {
    @Environment(AppViewModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.body)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("Items captured today")
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .kerning(-0.1)
                    .lineLimit(1)
                if model.isCapturePaused {
                    Text("capture paused")
                        .font(.caption2)
                        .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                }
            }
            Spacer(minLength: 4)
            Text("\(model.insightStore.atomsCapturedToday)")
                .font(.callout)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                .kerning(-0.1)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Color.orbitSurfaceMuted(for: colorScheme),
            in: RoundedRectangle(cornerRadius: OrbitShape.radiusControl)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SidebanePrivacyRow: View {
    @Environment(AppViewModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button {
            model.showPrivacyControls = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: model.isCapturePaused ? "hand.raised.fill" : "hand.raised")
                    .font(.body)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                    .frame(width: 20)
                Text("Privacy & setup")
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .kerning(-0.1)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                Color.orbitSurfaceMuted(for: colorScheme),
                in: RoundedRectangle(cornerRadius: OrbitShape.radiusControl)
            )
            .orbitHoverRow()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Privacy & setup")
    }
}

/// Opens Insights inline in the center pane (`MainWindowView`'s `mainContentMode`), matching
/// `TasksTabRow`'s two extra behaviours: a persistent selected-state accent tint, and
/// committing any in-flight Sidecard widget edit before leaving chat (otherwise `isEditing`
/// stays true on a Sidecard hidden by the mode switch — see
/// `AppViewModel.commitSidecardEditIfLeavingChat`). Clicking again while already on
/// `.insights` toggles back to `.chat`, exactly like Tasks/Timeline.
struct SidebaneUsageInsightsRow: View {
    @Environment(AppViewModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("mainContentMode") private var mainContentMode: MainContentMode = .chat

    private var isSelected: Bool { mainContentMode == .insights }

    var body: some View {
        Button {
            model.commitSidecardEditIfLeavingChat(from: mainContentMode)
            mainContentMode = isSelected ? .chat : .insights
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar")
                    .font(.body)
                    .foregroundStyle(isSelected ? Color.orbitAccent(for: colorScheme) : Color.orbitSecondaryText(for: colorScheme))
                    .frame(width: 20)
                Text("Insights")
                    .font(.callout)
                    .foregroundStyle(isSelected ? Color.orbitAccent(for: colorScheme) : .primary)
                    .kerning(-0.1)
                Spacer()
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
        .help("Insights")
    }
}
