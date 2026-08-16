import Foundation
import UserNotifications

@MainActor
final class DaemonNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = DaemonNotificationService()

    private var authorizationRequested = false

    private override init() {
        super.init()
    }

    func configure() {
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorizationIfNeeded() async {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func notifyDaemonStopped() {
        post(
            identifier: "com.orbit.daemon.stopped",
            title: "orbit capture stopped",
            body: "Live capture and AI features are offline. Historical context is still available."
        )
    }

    func notifyDaemonStarted() {
        post(
            identifier: "com.orbit.daemon.started",
            title: "orbit capture running",
            body: "The capture daemon is online and ready."
        )
    }

    /// Local banner when a routine run finishes (only if permission already granted).
    func notifyRoutineReady(title: String) {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = name.isEmpty ? "Routine" : name
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else { return }
            DispatchQueue.main.async {
                self.post(
                    identifier: "com.orbit.routine.ready.\(UUID().uuidString)",
                    title: "\(label) ready",
                    body: "Your routine finished. Review the prefilled chat prompt."
                )
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    private func post(identifier: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
