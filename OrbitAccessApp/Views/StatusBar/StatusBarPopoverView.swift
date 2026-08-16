import AppKit
import SwiftUI

struct StatusBarPopoverView: View {
    @Environment(AppViewModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("orbit")
                    .font(.headline)
                    .kerning(-0.1)
                Spacer()
                statusDot
            }
            .padding(.bottom, 12)

            OrbitHairlineDivider(horizontalPadding: 0)

            ProductivityScoreGauge(score: model.insightStore.productivityScore.value)
                .scaleEffect(0.85)
                .padding(.vertical, 12)

            OrbitHairlineDivider(horizontalPadding: 0)

            HStack {
                Label("\(model.taskStore.pendingTasks.count) tasks", systemImage: "checklist")
                    .font(.caption)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                Spacer()
                if let lastApp = model.insightStore.recentNotes.first?.appName {
                    Label(lastApp, systemImage: "app")
                        .font(.caption)
                        .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 12)

            OrbitHairlineDivider(horizontalPadding: 0)

            VStack(spacing: 8) {
                Button("open orbit") {
                    NotificationCenter.default.post(name: .openMainWindow, object: nil)
                }
                .buttonStyle(OrbitFlatButtonStyle(variant: .primary))

                HStack(spacing: 8) {
                    if model.isDaemonOnline {
                        OrbitButton(
                            label: "Stop",
                            variant: .secondary,
                            isLoading: isTransitioning || model.isDaemonStarting,
                            action: { Task { await model.stopDaemon() } }
                        )
                        .frame(maxWidth: .infinity)
                    } else {
                        OrbitButton(
                            label: "Start",
                            variant: .primary,
                            isLoading: isTransitioning || model.isDaemonStarting,
                            action: { Task { await model.startDaemon() } }
                        )
                        .frame(maxWidth: .infinity)
                    }
                }

                Button("quit orbit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(OrbitFlatButtonStyle(variant: .secondary))

                // The two exits are not equivalent and nothing on screen said so: closing the
                // window (X) is state B — no Dock icon, capture continues. Quitting is state C
                // — the daemon stops. Spelling it out here is the discoverable half of the
                // pair; the confirm alert in `AppDelegate.applicationShouldTerminate` is the
                // other half.
                Text("closing the window keeps capture running. quitting stops the daemon.")
                    .font(.caption2)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 12)

            if case .error(let message) = model.daemonControlState {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(Color.orbitScoreRed)
                    .lineLimit(2)
                    .padding(.top, 8)
            }
        }
        .padding(16)
        .frame(width: 280)
        .background(Color.orbitCanvas(for: colorScheme))
    }

    private var statusDot: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 6, height: 6)
            Text(statusLabel)
                .font(.caption2)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
        }
    }

    private var statusDotColor: Color {
        if !model.canBrowseContext { return .orbitAccent(for: colorScheme) }
        if model.isDaemonOnline {
            return model.isCapturePaused ? .orbitAccent(for: colorScheme) : .orbitScoreEmerald
        }
        return .orbitScoreRed
    }

    private var statusLabel: String {
        if !model.canBrowseContext { return "No database" }
        if model.canUseLiveServices { return "Online" }
        return "Browse only"
    }

    private var isTransitioning: Bool {
        switch model.daemonControlState {
        case .starting, .stopping:
            return true
        default:
            return false
        }
    }
}

extension Notification.Name {
    static let openMainWindow = Notification.Name("openMainWindow")
}
