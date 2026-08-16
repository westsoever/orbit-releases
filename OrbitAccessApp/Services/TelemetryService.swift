import Foundation
import OSLog
import PostHog
import Sentry

/// Crash reporting and usage analytics (launch-blockers #10) — Swift-side counterpart to
/// `orbit/telemetry.py`. Two cloud-hosted providers, both US-region by default:
///
/// - Sentry — crash/error reporting.
/// - PostHog — usage-event analytics ("what do users use the app for").
///
/// Opt-out, on by default — a deliberate product decision carried over unchanged from the
/// Python implementation (see `docs/launch-blockers.md` #10). Disable via the "Analytics"
/// toggle in Capture settings (`CaptureTierSettingsView`), which flips
/// `CapturePolicySettings.telemetryEnabled` (`telemetry_enabled` in `~/.orbit/policy.json`,
/// shared with the Python daemon).
///
/// Hard rule, not a suggestion: nothing sent here may ever contain captured window text,
/// URLs, search queries, chat messages, task prompts, file paths, or any other captured
/// content — only structural usage/crash metadata (which action fired, counts, durations,
/// mode/kind enums). ``scrub(_:)`` is defense in depth, mirroring Python's `_scrub_event`.
///
/// No-ops completely, with zero network activity, unless BOTH the policy flag is on AND the
/// provider's credentials (`ORBIT_SENTRY_DSN` / `ORBIT_POSTHOG_API_KEY`) are configured in
/// `~/.orbit/.env` — mirrors `orbit/telemetry.py:init_telemetry`'s exact no-op conditions.
final class TelemetryService: @unchecked Sendable {
    static let shared = TelemetryService()

    private static let logger = Logger(subsystem: "com.orbit.access", category: "Telemetry")

    private let sentryDSNKey = "ORBIT_SENTRY_DSN"
    private let posthogAPIKeyKey = "ORBIT_POSTHOG_API_KEY"
    private let posthogHostKey = "ORBIT_POSTHOG_HOST"
    private static let defaultPostHogHost = "https://us.i.posthog.com"

    /// Mirrors Python's `_SCRUB_KEYS` (`orbit/telemetry.py:76`) verbatim — the two lists must
    /// not drift. Any `extra`/`context` field on a Sentry event whose key (case-insensitively)
    /// matches this set is dropped before the event leaves the device.
    private static let scrubKeys: Set<String> = [
        "text", "window_title", "query", "message", "prompt", "url", "path", "content",
    ]

    private var sentryConfigured = false
    private var postHogConfigured = false
    private var lastPolicy: CapturePolicySettings?

    private init() {}

    /// Call once at app launch, from `AppDelegate.applicationDidFinishLaunching(_:)`.
    /// Safe to call multiple times or with telemetry disabled/unconfigured — every path below
    /// is a no-op unless both opted in and configured. Mirrors
    /// `orbit/telemetry.py:init_telemetry`'s exact no-op conditions.
    func initialize(policy: CapturePolicySettings) {
        lastPolicy = policy

        guard policy.telemetryEnabled else {
            Self.logger.info("Telemetry disabled by policy (telemetry_enabled=false).")
            return
        }

        startSentryIfConfigured()
        startPostHogIfConfigured()
    }

    /// Transitions telemetry live when the user flips the Settings toggle. Starts/stops
    /// each provider's SDK rather than leaving it running-but-muted, per §F/§G of the plan.
    func setEnabled(_ enabled: Bool, policy: CapturePolicySettings) {
        lastPolicy = policy

        guard enabled else {
            if sentryConfigured {
                SentrySDK.close()
                sentryConfigured = false
                Self.logger.info("Sentry crash reporting stopped (telemetry disabled).")
            }
            if postHogConfigured {
                PostHogSDK.shared.optOut()
                Self.logger.info("PostHog usage analytics opted out (telemetry disabled).")
            }
            return
        }

        startSentryIfConfigured()
        startPostHogIfConfigured()
        if postHogConfigured {
            PostHogSDK.shared.optIn()
        }
    }

    /// Fire a structural usage event. See the type doc-comment for what may NOT be passed in
    /// `properties` — no captured content, ever. Thin wrapper over `PostHogSDK.shared.capture`;
    /// no-ops if PostHog was never configured (unconfigured dev machine / disabled policy).
    func track(_ name: String, properties: [String: Any] = [:]) {
        guard postHogConfigured else { return }
        PostHogSDK.shared.capture(name, properties: properties)
    }

    /// Sentry `beforeSend` hook — defense in depth, not the primary guard. Drops any
    /// extra/context field whose key looks like it could carry captured content, in case it
    /// ever got attached. Mirrors Python's `_scrub_event` (`orbit/telemetry.py:79-95`).
    ///
    /// Note: Sentry Cocoa has no equivalent of Python's `include_local_variables` — confirmed
    /// absent from `SentryOptions`. Swift stack traces don't carry local-variable values the
    /// way Python's do, so this hook is the sole scrub point on this platform.
    static func scrub(_ event: Event) -> Event? {
        // `extra` is a flat [String: Any] — drop any top-level key that matches.
        if var extra = event.extra {
            for key in extra.keys where scrubKeys.contains(key.lowercased()) {
                extra.removeValue(forKey: key)
            }
            event.extra = extra
        }
        // `context` is one level deeper than Python's `contexts` — a dict of category name
        // (e.g. "app", "device") to its own [String: Any] — so the key match has to happen
        // inside each category's inner dict, not on the category names themselves.
        if var context = event.context {
            for (category, var fields) in context {
                for key in fields.keys where scrubKeys.contains(key.lowercased()) {
                    fields.removeValue(forKey: key)
                }
                context[category] = fields
            }
            event.context = context
        }
        return event
    }

    private func startSentryIfConfigured() {
        guard !sentryConfigured else { return }
        guard let dsn = readEnv(sentryDSNKey) else {
            Self.logger.info("ORBIT_SENTRY_DSN not set; crash reporting disabled.")
            return
        }
        SentrySDK.start { options in
            options.dsn = dsn
            // No performance tracing — this is crash reporting only.
            options.tracesSampleRate = 0.0
            options.sendDefaultPii = false
            options.beforeSend = { event in
                TelemetryService.scrub(event)
            }
        }
        sentryConfigured = true
        Self.logger.info("Sentry crash reporting initialized.")
    }

    private func startPostHogIfConfigured() {
        guard !postHogConfigured else { return }
        guard let apiKey = readEnv(posthogAPIKeyKey) else {
            Self.logger.info("ORBIT_POSTHOG_API_KEY not set; usage analytics disabled.")
            return
        }
        let host = readEnv(posthogHostKey) ?? Self.defaultPostHogHost
        let config = PostHogConfig(projectToken: apiKey, host: host)
        PostHogSDK.shared.setup(config)
        postHogConfigured = true
        Self.logger.info("PostHog usage analytics initialized.")
    }

    // MARK: - Secrets (`.env`-file mechanism only — never `ProcessInfo.environment`)
    //
    // Copies the read pattern from `LLMPreferencesService.envValue(for:)` exactly
    // (`OrbitAccessApp/Services/LLMPreferencesService.swift:147-160`). Telemetry never writes
    // to `.env` itself — DSN/API key are provisioned out-of-band, matching the Python side,
    // which only ever reads these two vars (`orbit/telemetry.py:_read_env`).

    private func readEnv(_ key: String) -> String? {
        guard let text = try? String(contentsOf: OrbitPaths.envFileURL, encoding: .utf8) else {
            return nil
        }
        let prefix = "\(key)="
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(prefix) {
                let value = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}
