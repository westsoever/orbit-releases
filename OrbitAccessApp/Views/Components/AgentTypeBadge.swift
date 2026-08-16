import SwiftUI

struct AgentTypeBadge: View {
    @Environment(\.colorScheme) private var colorScheme
    let agentType: AgentType

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: agentType.icon)
                .font(.caption2)
            Text(agentType.displayName)
                .font(.caption2.weight(.medium))
                .fixedSize()
        }
        .foregroundStyle(agentType.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.orbitSurfaceMuted(for: colorScheme), in: RoundedRectangle(cornerRadius: OrbitShape.radiusControl))
    }
}
