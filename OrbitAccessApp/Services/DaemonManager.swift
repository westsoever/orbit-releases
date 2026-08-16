import Foundation

enum DaemonControlState: Equatable {
    case offline
    case starting
    case running
    case stopping
    case error(String)
}

enum DaemonManagerError: LocalizedError {
    case orbitBinaryNotFound
    case startFailed(status: Int32)
    case stopFailed(status: Int32)
    case startTimeout

    var errorDescription: String? {
        switch self {
        case .orbitBinaryNotFound:
            return "orbit could not find its background service. Reinstall the app or set ORBIT_ROOT for development builds."
        case .startFailed:
            return "orbit could not start its background service. Quit and reopen the app, or check /tmp/orbit-daemon.log."
        case .stopFailed:
            return "orbit could not stop its background service cleanly."
        case .startTimeout:
            return "orbit's background service did not come online in time. Quit and reopen the app."
        }
    }
}

@MainActor
final class DaemonManager {
    private let bridge: OrbitBridgeClient
    private(set) var controlState: DaemonControlState = .offline

    init(bridge: OrbitBridgeClient) {
        self.bridge = bridge
    }

    func resolveOrbitBinary() throws -> URL {
        let fm = FileManager.default

        var candidates: [URL] = []
        if let root = ProcessInfo.processInfo.environment["ORBIT_ROOT"], !root.isEmpty {
            candidates.append(URL(fileURLWithPath: root).appendingPathComponent(".venv/bin/orbit"))
        }
        candidates.append(URL(fileURLWithPath: "/Applications/Orbit.app/Contents/Resources/orbit"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/orbit"))

        for url in candidates where fm.isExecutableFile(atPath: url.path) {
            return url
        }

        if let path = Self.which("orbit") {
            return URL(fileURLWithPath: path)
        }

        throw DaemonManagerError.orbitBinaryNotFound
    }

    func start() async throws {
        guard controlState != .starting else { return }

        if await bridge.checkStatus() {
            controlState = .running
            return
        }

        controlState = .starting
        defer {
            if controlState == .starting {
                controlState = .offline
            }
        }

        try await launchDaemon(retryAfterForceStop: true)
    }

    func stop() async throws {
        guard controlState != .stopping else { return }
        controlState = .stopping
        defer {
            if controlState == .stopping {
                controlState = .offline
            }
        }

        if await bridge.checkStatus() {
            do {
                try await bridge.requestShutdown()
                _ = await waitForOffline(timeoutSeconds: 10)
            } catch {
                // Fall through to CLI stop.
            }
        }

        try await runOrbitStop()
        _ = await waitForOffline(timeoutSeconds: 5)
        controlState = .offline
    }

    func syncControlState(isOnline: Bool, isCaptureActive: Bool) {
        switch controlState {
        case .starting, .stopping:
            break
        case .error:
            if isOnline {
                controlState = .running
            }
        case .offline, .running:
            controlState = isOnline ? .running : .offline
        }
    }

    private func launchDaemon(retryAfterForceStop: Bool) async throws {
        let binary = try resolveOrbitBinary()
        let status = try await runOrbitStart(binary: binary)
        guard status == 0 else {
            let error = DaemonManagerError.startFailed(status: status)
            controlState = .error(error.localizedDescription)
            throw error
        }

        if await waitForOnline(timeoutSeconds: 10) {
            controlState = .running
            return
        }

        if retryAfterForceStop {
            try await runOrbitStop()
            controlState = .starting
            try await launchDaemon(retryAfterForceStop: false)
            return
        }

        let error = DaemonManagerError.startTimeout
        controlState = .error(error.localizedDescription)
        throw error
    }

    private func runOrbitStart(binary: URL) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    process.executableURL = binary
                    process.arguments = ["start", "--detach", "--no-statusbar"]
                    var env = ProcessInfo.processInfo.environment
                    if env["ORBIT_ROOT"] == nil, let root = Self.inferOrbitRoot(from: binary) {
                        env["ORBIT_ROOT"] = root
                    }
                    process.environment = env
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runOrbitStop() async throws {
        let binary = try resolveOrbitBinary()
        let status = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    process.executableURL = binary
                    process.arguments = ["stop"]
                    var env = ProcessInfo.processInfo.environment
                    if env["ORBIT_ROOT"] == nil, let root = Self.inferOrbitRoot(from: binary) {
                        env["ORBIT_ROOT"] = root
                    }
                    process.environment = env
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        guard status == 0 else {
            let error = DaemonManagerError.stopFailed(status: status)
            controlState = .error(error.localizedDescription)
            throw error
        }
    }

    private func waitForOnline(timeoutSeconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await bridge.checkStatus() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return await bridge.checkStatus()
    }

    private func waitForOffline(timeoutSeconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if !(await bridge.checkStatus()) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return !(await bridge.checkStatus())
    }

    private static func which(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return path?.isEmpty == false ? path : nil
        } catch {
            return nil
        }
    }

    private nonisolated static func inferOrbitRoot(from binary: URL) -> String? {
        if binary.lastPathComponent == "orbit" {
            let resources = binary.deletingLastPathComponent()
            if resources.lastPathComponent == "Resources" {
                let core = resources.appendingPathComponent("orbit-core")
                if FileManager.default.fileExists(atPath: core.path) {
                    return core.path
                }
            }
        }
        let venvBin = binary.deletingLastPathComponent()
        guard venvBin.lastPathComponent == "bin", venvBin.deletingLastPathComponent().lastPathComponent == ".venv" else {
            return nil
        }
        return venvBin.deletingLastPathComponent().deletingLastPathComponent().path
    }
}
