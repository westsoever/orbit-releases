import Foundation

/// The subset of `~/.orbit/policy.json` (`orbit/capture/policy.py`'s `CapturePolicy`
/// dataclass) that the Settings scene exposes UI for (Plan 17 Phase 6.4).
///
/// Only 6 of the dataclass's ~13 fields are modeled here:
/// `tier_ax_text`, `tier_browser_ext`, and `work_hours_only` are parsed by Python but
/// never read anywhere in the capture pipeline — a working-looking toggle for a dead
/// flag is worse than no toggle, so they deliberately have no UI. `capture_paused` and
/// `excluded_bundles` already have full, bridge-backed UI in `PrivacyControlsView` /
/// `PrivacyStore` — this type must never touch those keys.
struct CapturePolicySettings: Codable, Equatable {
    var tierOcr: Bool
    var tierFsevents: Bool
    var retentionDays: Int
    var detectEnabled: Bool
    var detectDailyCap: Int
    /// Mirrors `CapturePolicy.telemetry_enabled` in `orbit/capture/policy.py` — opt-out,
    /// on by default (launch-blockers #10). Not bridge-backed; a local-only policy flag
    /// read by `TelemetryService`.
    var telemetryEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case tierOcr = "tier_ocr"
        case tierFsevents = "tier_fsevents"
        case retentionDays = "retention_days"
        case detectEnabled = "detect_enabled"
        case detectDailyCap = "detect_daily_cap"
        case telemetryEnabled = "telemetry_enabled"
    }

    /// Mirrors the Python dataclass's own defaults exactly (`policy.py`).
    static let defaults = CapturePolicySettings(
        tierOcr: false,
        tierFsevents: false,
        retentionDays: 90,
        detectEnabled: false,
        detectDailyCap: 5,
        telemetryEnabled: true
    )

    init(
        tierOcr: Bool,
        tierFsevents: Bool,
        retentionDays: Int,
        detectEnabled: Bool,
        detectDailyCap: Int,
        telemetryEnabled: Bool
    ) {
        self.tierOcr = tierOcr
        self.tierFsevents = tierFsevents
        self.retentionDays = retentionDays
        self.detectEnabled = detectEnabled
        self.detectDailyCap = detectDailyCap
        self.telemetryEnabled = telemetryEnabled
    }

    /// Per-key `decodeIfPresent`, not a single all-or-nothing `decode`: a real
    /// `policy.json` written before Plan 17 Phase 5 landed `detect_enabled` /
    /// `detect_daily_cap` has every other key but is missing those two. A strict
    /// decode would throw on the whole struct and silently fall back to *all*
    /// defaults, discarding the real `tier_ocr` / `tier_fsevents` / `retention_days`
    /// values that ARE present. Missing keys fall back individually instead.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tierOcr = try container.decodeIfPresent(Bool.self, forKey: .tierOcr) ?? Self.defaults.tierOcr
        tierFsevents = try container.decodeIfPresent(Bool.self, forKey: .tierFsevents) ?? Self.defaults.tierFsevents
        retentionDays = try container.decodeIfPresent(Int.self, forKey: .retentionDays) ?? Self.defaults.retentionDays
        detectEnabled = try container.decodeIfPresent(Bool.self, forKey: .detectEnabled) ?? Self.defaults.detectEnabled
        detectDailyCap = try container.decodeIfPresent(Int.self, forKey: .detectDailyCap) ?? Self.defaults.detectDailyCap
        telemetryEnabled = try container.decodeIfPresent(Bool.self, forKey: .telemetryEnabled) ?? Self.defaults.telemetryEnabled
    }
}

/// Direct-JSON-file read/write for `~/.orbit/policy.json`, following the same
/// convention as `RoutineStorage` (this app's established pattern for `~/.orbit/*.json`
/// config — a plain file, not a bridge round-trip).
///
/// `policy.json` is shared with the Python daemon (`orbit/capture/policy.py`'s
/// `load_policy`/`save_policy`), which writes *every* dataclass field, including ones
/// this app has no UI for (`excluded_bundles`, `ocr_allowlist`, `watch_roots`, the
/// three dead tiers). `save(_:)` therefore never round-trips through the partial
/// `CapturePolicySettings` struct — that would silently truncate the file to just the
/// 5 keys it knows about. Instead it does a read-modify-write over the raw JSON
/// object, updating only the keys this type owns and leaving everything else in the
/// file byte-for-byte as it already was.
enum CapturePolicyStorage {
    private static var fileURL: URL {
        OrbitPaths.policyURL
    }

    /// Load the UI-exposed subset of `policy.json`.
    /// Missing file, empty file, or corrupt JSON all fail soft to defaults — never
    /// crashes, never invents data, matches `RoutineStorage.load()`'s contract.
    static func load() -> CapturePolicySettings {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            return .defaults
        }
        guard let decoded = try? JSONDecoder().decode(CapturePolicySettings.self, from: data) else {
            return .defaults
        }
        return decoded
    }

    /// Read-modify-write: merges only the 5 keys `CapturePolicySettings` manages into
    /// whatever raw JSON object is already on disk (or an empty object if the file is
    /// missing/empty/corrupt), so every other field — `excluded_bundles`,
    /// `capture_paused`, `ocr_allowlist`, `watch_roots`, the dead tiers, and any future
    /// field this Swift type doesn't know about — survives untouched.
    static func save(_ settings: CapturePolicySettings) {
        try? OrbitPaths.ensureOrbitDirectoryExists()

        var raw: [String: Any] = [:]
        if let data = try? Data(contentsOf: fileURL), !data.isEmpty,
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            raw = existing
        }

        raw["tier_ocr"] = settings.tierOcr
        raw["tier_fsevents"] = settings.tierFsevents
        raw["retention_days"] = settings.retentionDays
        raw["detect_enabled"] = settings.detectEnabled
        raw["detect_daily_cap"] = settings.detectDailyCap
        raw["telemetry_enabled"] = settings.telemetryEnabled

        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(
                withJSONObject: raw,
                options: [.prettyPrinted, .sortedKeys]
              ) else {
            return
        }
        try? data.write(to: fileURL, options: .atomic)
    }
}
