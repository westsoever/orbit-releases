import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class PrivacyStore {
    var capturePaused = false
    var excludedBundles: [String] = []
    var builtinExclusions: [String] = []
    var setupChecklist: [SetupChecklistItem] = []
    var captureHealthApps: [CaptureHealthApp] = []
    var isLoading = false
    var statusMessage: String?
    var errorMessage: String?

    @ObservationIgnored private var bridge: OrbitBridgeProtocol?

    func configure(bridge: OrbitBridgeProtocol) {
        self.bridge = bridge
    }

    func refresh() async {
        guard let bridge else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let localAX = AccessibilityPermissions.isTrusted
        let daemonOnline = await bridge.checkStatus()

        if daemonOnline {
            do {
                let privacy = try await bridge.fetchPrivacyStatus()
                capturePaused = privacy.capturePaused
                excludedBundles = privacy.excludedBundles
                builtinExclusions = privacy.builtinExclusions
            } catch {
                errorMessage = error.localizedDescription
            }
            do {
                let setup = try await bridge.fetchSetupStatus()
                // Trust the daemon's own answer verbatim: it reports Accessibility
                // trust for the process that actually walks the AX tree (its
                // interpreter), not for this app. The app's own AXIsProcessTrusted()
                // probe (localAX) is only meaningful in the offline fallback path
                // below, where there is no daemon to ask.
                setupChecklist = setup.checklist
            } catch {
                setupChecklist = localFallbackChecklist(
                    daemonOnline: true,
                    capturePaused: capturePaused,
                    axTrusted: localAX
                )
            }
            do {
                let health = try await bridge.fetchCaptureHealth(hours: 24)
                captureHealthApps = health.apps
            } catch {
                captureHealthApps = []
            }
        } else {
            captureHealthApps = []
            setupChecklist = localFallbackChecklist(
                daemonOnline: false,
                capturePaused: capturePaused,
                axTrusted: localAX
            )
        }
    }

    func togglePause() async {
        guard let bridge else { return }
        errorMessage = nil
        do {
            let response = try await bridge.setCapturePaused(!capturePaused)
            capturePaused = response.capturePaused
            statusMessage = capturePaused ? "Capture paused" : "Capture resumed"
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addExclusion(_ bundleId: String) async {
        let trimmed = bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let bridge else { return }
        errorMessage = nil
        do {
            let response = try await bridge.updateExclusions(add: [trimmed], remove: [])
            excludedBundles = response.excludedBundles
            statusMessage = "Excluded \(trimmed)"
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeExclusion(_ bundleId: String) async {
        guard let bridge else { return }
        errorMessage = nil
        do {
            let response = try await bridge.updateExclusions(add: [], remove: [bundleId])
            excludedBundles = response.excludedBundles
            statusMessage = "Removed exclusion"
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func forget(minutes: Int) async {
        guard let bridge else { return }
        errorMessage = nil
        do {
            let response = try await bridge.forgetRecent(minutes: minutes)
            statusMessage = "Forgot \(response.deletedEvents) events from last \(minutes) min"
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func exportData() async {
        guard let bridge else { return }
        errorMessage = nil
        do {
            let response = try await bridge.exportCaptureData()
            statusMessage = "Exported \(response.events) events → \(response.path)"
            let url = URL(fileURLWithPath: response.path).deletingLastPathComponent()
            NSWorkspace.shared.open(url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteAll() async {
        guard let bridge else { return }
        errorMessage = nil
        do {
            try await bridge.deleteAllCaptureData()
            statusMessage = "Deleted all capture data"
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func localFallbackChecklist(
        daemonOnline: Bool,
        capturePaused: Bool,
        axTrusted: Bool
    ) -> [SetupChecklistItem] {
        let cloudAI = CloudAIService.shared
        let llmReady = cloudAI.isEnabled() || cloudAI.hasBYOK() || cloudAI.hasLocalLLM()
        let llmPath: String
        if cloudAI.hasLocalLLM() {
            llmPath = "ollama"
        } else if cloudAI.hasBYOK() {
            llmPath = "byok"
        } else if cloudAI.isEnabled() {
            llmPath = "cloud"
        } else {
            llmPath = "none"
        }
        return [
            SetupChecklistItem(
                id: "accessibility",
                label: "Accessibility permission",
                ok: axTrusted,
                detail: axTrusted ? nil : "Required for text capture"
            ),
            SetupChecklistItem(
                id: "daemon",
                label: "Capture daemon running",
                ok: daemonOnline,
                detail: daemonOnline ? "Bridge is reachable" : "Start the daemon from the sidebar"
            ),
            SetupChecklistItem(
                id: "llm",
                label: "LLM path (Cloud AI / Ollama / BYOK)",
                ok: llmReady,
                detail: llmPath
            ),
            SetupChecklistItem(
                id: "capture",
                label: "Capture not paused",
                ok: !capturePaused,
                detail: capturePaused ? "Paused" : "Active"
            ),
        ]
    }
}
