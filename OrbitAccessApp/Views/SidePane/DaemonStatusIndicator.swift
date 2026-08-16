import SwiftUI

struct DaemonStatusIndicator: View {
    @Environment(AppViewModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @State private var capturePulse = false

    var body: some View {
        HStack(spacing: 8) {
            statusDot
            VStack(alignment: .leading, spacing: 2) {
                Text(statusLabel)
                    .font(.caption)
                    .foregroundStyle(labelColor)
                    .kerning(-0.1)
                // Cap rail height: status label + at most one secondary line.
                secondaryLine
            }
            Spacer(minLength: 4)
            controlView
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        // Always retrievable, zero height cost — which is why the visible line can stay one short
        // token without hiding the app SHA, daemon SHA, package path, interpreter or daemon age.
        // contentShape makes the whole row (including padding and the Spacer's empty space)
        // hit-testable, so the tooltip isn't limited to the individual subviews' bounds.
        .contentShape(Rectangle())
        .help(model.buildProvenance?.detail ?? "orbit background service")
        .onChange(of: model.isCaptureActive) { _, active in
            if active && model.isDaemonOnline {
                withAnimation(OrbitMotion.pulse) {
                    capturePulse = true
                }
            } else {
                capturePulse = false
            }
        }
        .onAppear {
            if model.isCaptureActive && model.isDaemonOnline {
                capturePulse = true
            }
        }
    }

    @ViewBuilder
    private var secondaryLine: some View {
        // Divergence outranks everything below it: a mismatched build is frequently the *cause* of
        // the daemon error or the missing AI response those branches describe, so it must not be
        // the thing that gets hidden. The agreeing case stays last, where it is only informational.
        if let provenance = model.buildProvenance, provenance.level == .diverged {
            provenanceLine(provenance)
        } else if case .error(let message) = model.daemonControlState {
            Text(message)
                .font(.caption2)
                .foregroundStyle(Color.orbitScoreRed)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        } else if !model.canBrowseContext && !isTransitioning {
            // The app no longer opens ~/.orbit/orbit.db — the daemon owns it (plan 51 D1) —
            // so the only thing this state can mean now is that the daemon is unreachable.
            Text("orbit daemon is not reachable")
                .font(.caption2)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                .lineLimit(1)
        } else if model.isDaemonStarting {
            Text("orbit is starting in the background…")
                .font(.caption2)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                .lineLimit(1)
        // `canUseLiveServices` is currently defined as `isDaemonOnline` (AppViewModel), so this
        // guards the same thing today — but it stays explicit so a stopped daemon never shows
        // "browsing saved context" (it should just say "Daemon stopped"), and so the line comes
        // back automatically if live-service readiness is ever decoupled from process liveness.
        } else if model.isDaemonOnline && model.canBrowseContext && !model.canUseLiveServices && !isTransitioning {
            Text("Browsing saved context — background capture paused")
                .font(.caption2)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                .lineLimit(1)
        } else if let provenance = model.buildProvenance {
            provenanceLine(provenance)
        }
    }

    /// One short line; the full app/daemon/path/age breakdown lives in the row's `.help(…)`,
    /// which costs no height. Only the diverged label needs two lines to stay readable.
    @ViewBuilder
    private func provenanceLine(_ provenance: BuildProvenance) -> some View {
        Text(provenance.label)
            .font(.caption2)
            .foregroundStyle(provenanceColor(provenance.level))
            .lineLimit(provenance.level == .diverged ? 2 : 1)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func provenanceColor(_ level: BuildProvenance.Level) -> Color {
        switch level {
        case .matched:
            return Color.orbitSecondaryText(for: colorScheme)
        case .unverified:
            return Color.orbitScoreAmber
        case .diverged:
            return Color.orbitScoreRed
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        if isTransitioning {
            ProgressView()
                .controlSize(.small)
                .frame(width: 8, height: 8)
        } else {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .scaleEffect(model.isCaptureActive && model.isDaemonOnline && capturePulse ? 1.35 : 1.0)
                .animation(
                    model.isCaptureActive && model.isDaemonOnline
                        ? OrbitMotion.pulse
                        : OrbitMotion.standard,
                    value: capturePulse
                )
        }
    }

    @ViewBuilder
    private var controlView: some View {
        if model.isDaemonOnline {
            OrbitButton(
                label: "Stop",
                variant: .secondary,
                isLoading: isTransitioning,
                action: { Task { await model.stopDaemon() } }
            )
        } else {
            OrbitButton(
                label: "Start",
                variant: .primary,
                isLoading: isTransitioning,
                action: { Task { await model.startDaemon() } }
            )
        }
    }

    private var isTransitioning: Bool {
        switch model.daemonControlState {
        case .starting, .stopping:
            return true
        default:
            return false
        }
    }

    private var statusLabel: String {
        switch model.daemonControlState {
        case .starting:
            return "Starting…"
        case .stopping:
            return "Stopping…"
        case .error:
            return "Daemon offline"
        case .running, .offline:
            if !model.canBrowseContext {
                // `canBrowseContext` now tracks daemon reachability, not a local DB open.
                return "Daemon unreachable"
            }
            if model.isDaemonOnline {
                if model.isCapturePaused {
                    return "Capture paused"
                }
                return model.isCaptureActive ? "Capturing" : "Daemon running"
            }
            return "Daemon stopped"
        }
    }

    private var dotColor: Color {
        if !model.canBrowseContext {
            return Color.orbitAccent(for: colorScheme)
        }
        if model.isDaemonOnline {
            return model.isCapturePaused ? Color.orbitAccent(for: colorScheme) : Color.orbitScoreEmerald
        }
        return Color.orbitScoreRed
    }

    private var labelColor: Color {
        if !model.canBrowseContext {
            return Color.orbitAccent(for: colorScheme)
        }
        return model.isDaemonOnline ? Color.primary : Color.orbitSecondaryText(for: colorScheme)
    }
}
