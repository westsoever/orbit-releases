import AppKit
import ApplicationServices
import Foundation

enum AccessibilityPermissions {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Opens System Settings → Privacy & Security → Accessibility when possible.
    ///
    /// Tries the modern System Settings deep link first, falling back to the legacy
    /// System Preferences pane URL on macOS versions where the modern link doesn't
    /// resolve. Note: `NSWorkspace.open` returning `true` only means *something*
    /// opened (e.g. System Settings itself) — it is not proof the Accessibility pane
    /// actually landed in front of the user.
    @discardableResult
    static func openSystemSettings() -> Bool {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return true
            }
        }
        return false
    }
}
