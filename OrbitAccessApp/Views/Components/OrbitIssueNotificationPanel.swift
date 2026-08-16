import SwiftUI

struct OrbitIssueNotificationPanel: View {
    let issue: OrbitIssue
    let onAction: () -> Void

    var body: some View {
        OrbitCard(accent: .orbitScoreRed) {
            HStack(alignment: .top, spacing: 8) {
                Text(issue.message)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle = issue.actionTitle {
                    Button(actionTitle, action: onAction)
                        .buttonStyle(OrbitFlatButtonStyle(variant: .secondary, size: .sm))
                        .fixedSize()
                }
            }
        }
    }
}

struct OrbitIssueNotificationHost: View {
    let issue: OrbitIssue
    let onAction: () -> Void

    @State private var ping = false

    var body: some View {
        OrbitIssueNotificationPanel(issue: issue, onAction: onAction)
            .frame(maxWidth: 320)
            .scaleEffect(ping ? 1.0 : 0.92)
            .opacity(ping ? 1.0 : 0.0)
            .onAppear { animateIn() }
            .onChange(of: issue.id) { _, _ in animateIn() }
    }

    private func animateIn() {
        ping = false
        withAnimation(OrbitMotion.emphasis) {
            ping = true
        }
    }
}
