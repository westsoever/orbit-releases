import Foundation

enum OrbitPaths {
    static var orbitDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".orbit", isDirectory: true)
    }

    static var databaseURL: URL {
        orbitDirectory.appendingPathComponent("orbit.db", isDirectory: false)
    }

    static var accessAppLockURL: URL {
        orbitDirectory.appendingPathComponent("access-app.lock", isDirectory: false)
    }

    /// Installed app bundle: Contents/Resources/orbit-core (ORBIT_ROOT for production installs).
    static var bundledOrbitCoreURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/orbit-core", isDirectory: true)
    }

    static func defaultOrbitRoot() -> String? {
        if let root = ProcessInfo.processInfo.environment["ORBIT_ROOT"], !root.isEmpty {
            return root
        }
        let core = bundledOrbitCoreURL
        if FileManager.default.fileExists(atPath: core.path) {
            return core.path
        }
        return nil
    }

    static var cloudConfigURL: URL {
        orbitDirectory.appendingPathComponent("cloud.json", isDirectory: false)
    }

    static var policyURL: URL {
        orbitDirectory.appendingPathComponent("policy.json", isDirectory: false)
    }

    static var envFileURL: URL {
        orbitDirectory.appendingPathComponent(".env", isDirectory: false)
    }

    static var bridgeTokenURL: URL {
        orbitDirectory.appendingPathComponent("bridge.token", isDirectory: false)
    }

    static var sessionURL: URL {
        orbitDirectory.appendingPathComponent("session.json", isDirectory: false)
    }

    static func loadBridgeToken() -> String? {
        let url = bridgeTokenURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let token = data.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    static func ensureOrbitDirectoryExists() throws {
        try FileManager.default.createDirectory(at: orbitDirectory, withIntermediateDirectories: true)
    }

    /// Both `docs/gdpr/` and a flat `docs/` are accepted, in that order.
    ///
    /// The development tree keeps the policy in `docs/gdpr/` next to the drafting templates;
    /// the public distribution repo publishes it flat in `docs/`, because that is the path
    /// shipped builds already link to from the About panel and those URLs cannot move without
    /// breaking every installed copy. `build-app-bundle.sh` normalises either layout into
    /// `docs/gdpr/` inside the bundle, so the bundled branch below needs only the one path —
    /// it is the source-tree branches that can see either shape.
    private static let policyRelativePaths = [
        "docs/gdpr/PRIVACY_POLICY.md",
        "docs/PRIVACY_POLICY.md",
    ]

    static func privacyPolicyURL() -> URL? {
        if let root = defaultOrbitRoot() {
            let base = URL(fileURLWithPath: root)
            for relative in policyRelativePaths {
                let url = base.appendingPathComponent(relative)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        let bundled = bundledOrbitCoreURL.appendingPathComponent("docs/gdpr/PRIVACY_POLICY.md")
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let devCandidates = policyRelativePaths.map { repoRoot.appendingPathComponent($0) }
        return devCandidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
