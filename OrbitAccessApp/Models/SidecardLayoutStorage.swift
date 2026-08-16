import Foundation

enum SidecardLayoutStorage {
    private static var fileURL: URL {
        OrbitPaths.orbitDirectory.appendingPathComponent("sidecards.json")
    }

    /// Load the sidecard layout from `~/.orbit/sidecards.json`.
    /// Seeds defaults only when the file is missing. A saved empty array stays empty.
    static func load() -> [SidecardLayoutEntry] {
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            let seeded = defaults
            save(seeded)
            return seeded
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            return []
        }
        // Empty file → empty list (do not re-seed).
        if data.isEmpty {
            return []
        }
        let decoder = JSONDecoder()
        // Decode element-by-element so one entry with a stale/unrecognized widget
        // rawValue doesn't sink the whole array (JSONDecoder normally fails the
        // entire array decode if any single element throws).
        if let lossyDecoded = try? decoder.decode([LossyLayoutEntry].self, from: data) {
            let decoded = lossyDecoded.compactMap(\.entry)
            return reconciled(decoded)
        }
        // Corrupt JSON: fail soft without crashing or overwriting the file.
        return defaults
    }

    /// Wraps a single decode attempt so a per-entry failure (e.g. an unrecognized
    /// `SidecardWidget` rawValue) yields `nil` instead of throwing and failing the
    /// entire top-level array decode.
    private struct LossyLayoutEntry: Decodable {
        let entry: SidecardLayoutEntry?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            entry = try? container.decode(SidecardLayoutEntry.self)
        }
    }

    static func save(_ layout: [SidecardLayoutEntry]) {
        try? OrbitPaths.ensureOrbitDirectoryExists()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(layout) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Restore and persist the default layout, returning it.
    @discardableResult
    static func resetToDefaults() -> [SidecardLayoutEntry] {
        let reset = defaults
        save(reset)
        return reset
    }

    /// Forward-compatible reconciliation: append any widgets missing from the decoded
    /// layout (so a future widget appears), preserving the decoded ordering and state.
    private static func reconciled(_ decoded: [SidecardLayoutEntry]) -> [SidecardLayoutEntry] {
        var result = decoded
        let known = Set(decoded.map(\.widget))
        for widget in SidecardWidget.allCases where !known.contains(widget) {
            result.append(SidecardLayoutEntry(widget: widget, isVisible: true, isCollapsed: false))
        }
        return result
    }

    /// New installs lead with Today: describing the captured context is the MVP's second
    /// step and belongs at the top of the column.
    ///
    /// Existing installs are a different story, and honestly so: `reconciled(_:)` appends
    /// a widget the saved file has never seen at the **end** of the column (visible and
    /// uncollapsed), so an existing user finds Today at the bottom until they drag it up.
    /// That is deliberate — silently reordering someone's saved layout would be worse than
    /// a card in an unexpected place, so no migration reorders it.
    private static var defaults: [SidecardLayoutEntry] {
        [
            SidecardLayoutEntry(widget: .todaySummary, isVisible: true, isCollapsed: false),
            SidecardLayoutEntry(widget: .recommendedTasks, isVisible: true, isCollapsed: false),
            SidecardLayoutEntry(widget: .todaysSchedule, isVisible: true, isCollapsed: false),
            SidecardLayoutEntry(widget: .routines, isVisible: true, isCollapsed: false),
            SidecardLayoutEntry(widget: .contextStream, isVisible: true, isCollapsed: false),
        ]
    }
}
