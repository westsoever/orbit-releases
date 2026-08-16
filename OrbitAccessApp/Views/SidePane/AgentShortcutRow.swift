import SwiftUI

struct AgentShortcutRow: View {
    @Environment(AppViewModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("mainContentMode") private var mainContentMode: MainContentMode = .chat
    let agentType: AgentType

    var body: some View {
        Button {
            Task { await AgentPromptFunction(agentType: agentType).execute(model.aiContext()) }
            mainContentMode = .chat
        } label: {
            HStack(spacing: 8) {
                Image(systemName: agentType.icon)
                    .font(.body)
                    .foregroundStyle(agentType.color)
                    .frame(width: 20)
                Text(agentType.displayName)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .kerning(-0.1)
                Spacer(minLength: 0)
                Color.clear
                    .frame(width: SidebaneMetrics.menuAffordanceWidth)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.orbitSurfaceMuted(for: colorScheme), in: RoundedRectangle(cornerRadius: OrbitShape.radiusControl))
            .orbitHoverRow(tint: agentType.color)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
