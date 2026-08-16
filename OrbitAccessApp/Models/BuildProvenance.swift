import Foundation

/// "Am I talking to the build I think I am?" — the app's own stamp against the daemon's self-report.
///
/// Plan 34 phase 2. The Swift half and the Python half are built and restarted independently, and a
/// stale daemon is indistinguishable from a fresh one until something silently stops working. This
/// reduces the comparison to one short line, because the sidebane rail is only
/// `SidebaneMetrics.columnWidth` (220pt) wide and a truncated identity is worse than no identity.
struct BuildProvenance: Equatable {
    enum Level: Equatable {
        /// Both sides reported a SHA, they are equal, and neither tree is dirty — actual proof.
        case matched
        /// Nothing contradicts, but nothing was proven either: a dirty tree, or a side that
        /// reported no SHA to compare. Never renders one side's SHA as if it were shared.
        case unverified
        /// Demonstrably different builds.
        case diverged
    }

    let level: Level
    /// Short enough for the rail: `build cab386c` when agreeing, `app X ≠ daemon Y` when not.
    let label: String
    /// Everything the short line drops, for `.help(...)` on hover.
    let detail: String
}

/// What the app knows about its own build, from the keys the build scripts stamp.
struct AppBuildStamp: Equatable {
    let sha: String?
    let dirty: Bool
    /// UTC ISO-8601 recorded at the start of the build run that produced this bundle.
    let builtAt: String?

    /// Written by `stamp_orbit_build_identity()` in scripts/orbit_access_bundle_resources.sh.
    /// Custom keys rather than CFBundleVersion, which Apple requires to be numeric.
    static func fromMainBundle() -> AppBuildStamp {
        let info = Bundle.main.infoDictionary
        let sha = info?["OrbitBuildSHA"] as? String
        return AppBuildStamp(
            sha: (sha == nil || sha == "unknown") ? nil : sha,
            dirty: info?["OrbitBuildDirty"] as? Bool ?? false,
            builtAt: info?["OrbitBuildTime"] as? String
        )
    }
}

extension BuildProvenance {
    /// nil when the daemon reports no build identity at all — either it is offline, or it predates
    /// the fields, in which case there is nothing to compare and inventing a verdict would lie.
    ///
    /// `app` and `repoRoot` default to the live environment and are parameters only so the verdict
    /// can be exercised without an app bundle around it.
    static func resolve(
        daemon: DaemonBuildInfo?,
        app: AppBuildStamp = .fromMainBundle(),
        repoRoot: String? = devRepoRoot()
    ) -> BuildProvenance? {
        guard let daemon, daemon.gitSha != nil || daemon.version != nil else { return nil }
        // (rail label, hover explanation). The label names what actually differs — writing
        // "app X ≠ daemon X" for a timestamp or interpreter mismatch would read as a bug in
        // the check itself.
        var reasons: [(String, String)] = []

        if let appSHA = app.sha, let daemonSHA = daemon.gitSha, appSHA != daemonSHA {
            reasons.append((
                "app \(appSHA) ≠ daemon \(daemonSHA)",
                "app built from \(appSHA), daemon running \(daemonSHA)"
            ))
        }
        // OrbitBuildTime is taken before the build script restarts the daemon, so in a healthy run
        // the daemon is always *newer*. Older means it survived the build and kept its old Python —
        // the one comparison that catches uncommitted edits, which SHAs cannot see.
        // Limitation: a bundle stamped before OrbitBuildTime existed has builtAt == nil, and this
        // check then silently does not run. Transitional only; the next rebuild stamps the key.
        if let builtAt = app.builtAt, let startedAt = daemon.startedAt,
           instant(startedAt) < instant(builtAt) {
            reasons.append((
                "daemon predates build",
                "daemon started \(startedAt), before this build (\(builtAt))"
            ))
        }
        // Path checks apply only to a dev build: a release bundle's ORBIT_ROOT points inside
        // itself and its daemon lives in the embedded venv, so no containment holds there.
        // Consequence worth naming: on the release track there is *no* source-location check at
        // all, and the SHA comparison is the only guard (see the .unverified fallthrough below).
        // Compared as literal prefixes — a symlinked repo root would read as outside it, which
        // is rare enough to leave to the hover detail rather than resolve on every poll.
        if let root = repoRoot {
            if let path = daemon.packagePath, !isContained(path, in: root) {
                reasons.append((
                    "daemon: wrong source",
                    "daemon loads orbit from \(path), outside \(root)"
                ))
            }
            if let interpreter = daemon.interpreter, !isContained(interpreter, in: root) {
                reasons.append((
                    "daemon: wrong venv",
                    "daemon runs \(interpreter), outside \(root)"
                ))
            }
        }

        let detail = detailText(app: app, daemon: daemon, reasons: reasons.map(\.1))

        if let headline = reasons.first?.0 {
            return BuildProvenance(level: .diverged, label: headline, detail: detail)
        }
        // Nothing contradicted — but "no contradiction" is only proof when there was something to
        // compare. A side without a SHA was never checked, so name the missing side rather than
        // printing the other one's SHA: `build cab386c` would read as "both are cab386c".
        // Reachable on the release track when install.sh builds from a tarball (no checkout, so
        // OrbitBuildSHA is "unknown" and BUILD_SHA is never written).
        switch (app.sha, daemon.gitSha) {
        case (nil, nil):
            return BuildProvenance(level: .unverified, label: "build unknown", detail: detail)
        case (nil, _):
            return BuildProvenance(level: .unverified, label: "app: no build SHA", detail: detail)
        case (_, nil):
            return BuildProvenance(level: .unverified, label: "daemon: no build SHA", detail: detail)
        case (let appSHA?, _):
            let dirty = app.dirty || (daemon.gitDirty ?? false)
            return BuildProvenance(
                level: dirty ? .unverified : .matched,
                label: "build \(appSHA)\(dirty ? "*" : "")",
                detail: detail
            )
        }
    }

    // MARK: - Environment

    /// Repo root of a dev build, or nil for a release bundle, whose ORBIT_ROOT points inside itself.
    static func devRepoRoot() -> String? {
        guard let root = ProcessInfo.processInfo.environment["ORBIT_ROOT"],
              !root.isEmpty,
              !root.hasPrefix(Bundle.main.bundleURL.path) else { return nil }
        return root
    }

    private static func isContained(_ path: String, in root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Both stamps are UTC ISO-8601, so the leading `YYYY-MM-DDTHH:MM:SS` orders them without
    /// paying for date parsing. Truncating is safe precisely because neither side carries an offset
    /// other than UTC — the daemon uses `datetime.now(timezone.utc)`, the scripts use `date -u`.
    private static func instant(_ stamp: String) -> String {
        String(stamp.prefix(19))
    }

    private static func detailText(
        app: AppBuildStamp,
        daemon: DaemonBuildInfo,
        reasons: [String]
    ) -> String {
        var lines: [String] = []
        lines.append("App build \(app.sha ?? "unknown")\(app.dirty ? " (uncommitted edits)" : "")")
        if let builtAt = app.builtAt {
            lines.append("  built \(builtAt)")
        }
        var daemonLine = "Daemon \(daemon.gitSha ?? "no build SHA")"
        if daemon.gitDirty == true {
            daemonLine += " (uncommitted edits)"
        }
        if let version = daemon.version {
            daemonLine += ", orbit \(version)"
        }
        lines.append(daemonLine)
        if let startedAt = daemon.startedAt {
            lines.append("  started \(startedAt)\(age(since: startedAt).map { " (\($0) ago)" } ?? "")")
        }
        if let path = daemon.packagePath {
            lines.append("  \(path)")
        }
        if let interpreter = daemon.interpreter {
            lines.append("  \(interpreter)")
        }
        lines.append(contentsOf: reasons.map { "⚠ \($0)" })
        return lines.joined(separator: "\n")
    }

    /// Coarse "4m" / "3h" / "2d" — enough to tell a just-restarted daemon from yesterday's.
    private static func age(since stamp: String) -> String? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let started = formatter.date(from: stamp)
            ?? ISO8601DateFormatter().date(from: stamp)
        guard let started else { return nil }
        let seconds = Int(Date().timeIntervalSince(started))
        guard seconds >= 0 else { return nil }
        if seconds < 3600 { return "\(max(seconds / 60, 1))m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }
}
