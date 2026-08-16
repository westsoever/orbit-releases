import AppKit

/// Turns the main window's close button into a **hide**, so pressing X drops the Dock icon
/// and leaves the app in the menu bar with the daemon still capturing (state B) instead of
/// destroying the window.
///
/// Why a delegate rather than only observing `NSWindow.willCloseNotification`
/// (`AppDelegate.mainWindowWillClose`): `willClose` is posted *after* the close is already
/// committed, so a SwiftUI `WindowGroup` scene is torn down along with the window.
/// `StatusBarController.openMainWindow()` would then find no window with identifier `"main"`
/// to bring back, and re-creating the scene would re-run the WindowGroup's `.task`
/// (`OrbitAccessApp.swift:18-23`) and therefore `AppViewModel.start()` a second time.
/// `windowShouldClose(_:)` is the only hook that stops the close *before* it happens, and it
/// covers every user-facing close path — the red button, ⌘W and File ▸ Close all route
/// through `NSWindow.performClose(_:)`, which consults the delegate. Quitting is unaffected:
/// `NSApp.terminate(_:)` does not consult `windowShouldClose(_:)`, so state C still works.
///
/// SwiftUI installs its own delegate on `WindowGroup` windows. `NSWindow.delegate` is a weak
/// reference, so this object both **retains** the delegate it displaces and forwards every
/// selector it does not implement to it, using `NSObject`'s standard message-forwarding
/// hooks (`responds(to:)` + `forwardingTarget(for:)`). That keeps SwiftUI's scene bookkeeping
/// (resize, key/main changes, restoration) intact.
final class MainWindowCloseInterceptor: NSObject, NSWindowDelegate {
    /// Held strongly on purpose: `NSWindow.delegate` is weak, so once we take the slot
    /// nothing else is guaranteed to keep SwiftUI's delegate alive.
    private let forwardee: NSObjectProtocol?
    private let onHide: (NSWindow) -> Void

    init(forwardee: NSObjectProtocol?, onHide: @escaping (NSWindow) -> Void) {
        self.forwardee = forwardee
        self.onHide = onHide
        super.init()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onHide(sender)
        return false
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return forwardee?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        guard let forwardee, forwardee.responds(to: aSelector) else { return nil }
        return forwardee
    }
}
