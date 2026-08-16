import AppKit
import SwiftUI

/// Content for the `todaySummary` sidecard: what Orbit saw today, as written by the
/// daemon's `build_digest`. `SidecardShell` supplies the chrome; this view only renders.
struct TodaySummaryCard: View {
    @Environment(AppViewModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    private var insight: InsightStore { model.insightStore }
    private var narrative: String { insight.digestNarrative ?? "" }
    /// True when the daemon counted rows instead of writing prose — either because no AI
    /// is configured or because the completion failed and `build_digest` degraded.
    private var isStructured: Bool { insight.digestSource == "structured" }

    /// True when there is anything worth rendering in the Resume block. `todaySummary`
    /// is the widget that already sits above `recommendedTasks` in the default sidecard
    /// layout (`SidecardLayoutStorage.defaults`), so this is "above the task list"
    /// without inventing a sixth `SidecardWidget` case for one small, zero-cost card.
    private var hasResumeContent: Bool {
        insight.lastSessionTitle?.isEmpty == false
            || insight.lastSessionSummary?.isEmpty == false
            || insight.lastSessionAppName?.isEmpty == false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasResumeContent {
                resumeSection
                OrbitHairlineDivider(horizontalPadding: 0)
            }
            summaryBody

            if insight.digestSessionCount > 0 || insight.digestEventCount > 0 {
                Text(countsLine)
                    .font(.caption2)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Never let a stat line read as an AI narrative on a demo screen.
            if isStructured, !narrative.isEmpty {
                Text("Counted from capture, not written by AI.")
                    .font(.caption2)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
            }

            if let error = insight.digestError, !narrative.isEmpty {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(Color.orbitScoreRed)
                    .fixedSize(horizontal: false, vertical: true)
            }

            footer
        }
    }

    /// "Resume where you left off" — the last session's title/summary/files, straight
    /// from `get_sessions`/`current_session` (Plan 17 Phase 3) with no LLM call and no
    /// approval gate, so it is safe to show unconditionally whenever it has content.
    @ViewBuilder
    private var resumeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Resume")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))

            if let title = insight.lastSessionTitle, !title.isEmpty {
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
            } else if let appName = insight.lastSessionAppName, !appName.isEmpty {
                Text(appName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }

            if let summary = insight.lastSessionSummary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let filesLine {
                Text(filesLine)
                    .font(.caption2)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if insight.lastSessionBundleId != nil {
                Button("Reopen") { reopenLastSession() }
                    .buttonStyle(OrbitFlatButtonStyle(variant: .secondary, size: .sm))
                    .help("Bring \(insight.lastSessionAppName ?? "the last app") to the front")
            }
        }
    }

    private var filesLine: String? {
        guard !insight.lastSessionFiles.isEmpty else { return nil }
        let names = insight.lastSessionFiles.prefix(3).map { ($0 as NSString).lastPathComponent }
        let extra = insight.lastSessionFiles.count - names.count
        let joined = names.joined(separator: ", ")
        return extra > 0 ? "\(joined) +\(extra) more" : joined
    }

    private func reopenLastSession() {
        guard let bundleId = insight.lastSessionBundleId,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    @ViewBuilder
    private var summaryBody: some View {
        if insight.isDigestLoading, narrative.isEmpty {
            LoadingIndicator(label: "Reading today…")
        } else if !narrative.isEmpty {
            Text(narrative)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        } else if let error = insight.digestError {
            Text(error)
                .font(.caption)
                .foregroundStyle(Color.orbitScoreRed)
                .fixedSize(horizontal: false, vertical: true)
        } else if !model.canUseLiveServices {
            Text("orbit's background service is not running, so there is no summary for today yet.")
                .font(.caption)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Nothing captured yet today. Use your machine for a while and refresh.")
                .font(.caption)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Ask about today") {
                // Prefill and focus only — the user presses send. Same two calls as
                // AppViewModel.runRoutine; "What did I work on today?" is routed down the
                // digest path by the daemon's is_temporal_recap_query.
                model.chatStore.prefillInput("What did I work on today?")
                model.chatStore.requestFocus()
            }
            .buttonStyle(OrbitFlatButtonStyle(variant: .secondary, size: .sm))

            Spacer(minLength: 4)

            OrbitIconButton(
                label: refreshLabel,
                systemImage: "arrow.clockwise",
                variant: .ghost,
                size: .sm,
                isLoading: insight.isDigestLoading,
                isDisabled: !model.canUseLiveServices
            ) {
                // The only user-initiated LLM narrative request in the app.
                Task { await insight.refreshDigest(bridge: model.bridge, useLLM: true) }
            }
        }
    }

    private var refreshLabel: String {
        model.canUseLiveServices
            ? "Write a fresh summary of today"
            : "orbit's background service is not running"
    }

    private var countsLine: String {
        var parts = ["\(insight.digestSessionCount) sessions"]
        parts.append("\(insight.digestEventCount) events")
        if insight.digestAtomCount > 0 {
            parts.append("\(insight.digestAtomCount) atoms")
        }
        return parts.joined(separator: " · ")
    }
}
