import Foundation

enum RoutineStorage {
    private static var fileURL: URL {
        OrbitPaths.orbitDirectory.appendingPathComponent("routines.json")
    }

    /// Load routines from `~/.orbit/routines.json`.
    /// Seeds defaults only when the file is missing. A saved empty array stays empty.
    static func load() -> [RoutineBlock] {
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
        if let decoded = try? decoder.decode([RoutineBlock].self, from: data) {
            // Crash mid-run can leave runState == .running on disk; coerce to idle on load.
            return decoded.map { routine in
                guard routine.runState == .running else { return routine }
                var cleared = routine
                cleared.runState = .idle
                return cleared
            }
        }
        // Corrupt JSON: fail soft without crashing or overwriting the file.
        return []
    }

    static func save(_ routines: [RoutineBlock]) {
        try? OrbitPaths.ensureOrbitDirectoryExists()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(routines) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private static var defaults: [RoutineBlock] {
        [
            RoutineBlock(id: "deep-work", title: "Deep work", startTime: "09:00", endTime: "12:00"),
            RoutineBlock(id: "admin", title: "Admin & email", startTime: "13:00", endTime: "14:00"),
            RoutineBlock(id: "collab", title: "Meetings", startTime: "14:00", endTime: "17:00"),
        ]
    }
}
