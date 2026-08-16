import SwiftUI

enum OrbitMotion {
    /// The project's collapse spring: pane toggles, sidecard collapse, task-card expansion.
    static let collapse = Animation.spring(response: 0.3, dampingFraction: 0.85)

    /// Notification / emphasis ping — from OrbitIssueNotificationPanel.
    static let emphasis = Animation.spring(response: 0.35, dampingFraction: 0.62)

    /// Pointer enter/exit. Fast enough to feel attached to the cursor.
    static let hover = Animation.easeOut(duration: 0.12)

    /// Press-down / release.
    static let press = Animation.easeOut(duration: 0.09)

    /// Selection and filter changes.
    static let selection = Animation.easeOut(duration: 0.15)

    /// Chat view swap and bubble insertion.
    static let fade = Animation.easeInOut(duration: 0.2)

    /// Productivity score reveal.
    static let scoreReveal = Animation.easeInOut(duration: 1.0)

    /// Capture-active pulse.
    static let pulse = Animation.easeInOut(duration: 0.8).repeatForever(autoreverses: true)

    /// Scroll-to-bottom and other transitions that deliberately use the
    /// system default curve. Named so the choice is explicit, not accidental.
    static let standard = Animation.default
}
