import AppKit

extension Notification.Name {
    static let orbitAccessActivate = Notification.Name("com.orbit.access.activate")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private weak var viewModel: AppViewModel?
    /// `NSWindow.delegate` is weak, so the interceptors have to be owned here. One per main
    /// window; in practice there is exactly one (⌘N is rebound to New Chat, so the
    /// `WindowGroup` never spawns a second).
    private var closeInterceptors: [MainWindowCloseInterceptor] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        configureInstalledOrbitRoot()
        disableAutomaticTermination()
        _ = enforceSingleInstance()
    }

    /// macOS **Automatic Termination** (TAL) is a mechanism entirely separate from
    /// `applicationShouldTerminateAfterLastWindowClosed(_:)`, and returning `false` there does
    /// not hold it off. AppKit opts the process in by itself once no window is on screen —
    /// observed in the unified log right after the close button was clicked:
    ///
    ///     [com.apple.AppKit:AutomaticTermination] _NSEnableAutomaticTerminationAndLog
    ///         No windows open yet
    ///     [com.apple.AppKit:AutomaticTermination] _updateToReflectAutomaticTerminationState
    ///         Setting _kLSApplicationWouldBeTerminatedByTALKey=1
    ///
    /// The system then quit Orbit as soon as another app was activated, and that quit ran the
    /// normal termination path, so capture stopped even though the user had only closed a
    /// window. For a menu-bar-resident capture app, "windowless and in the background" is the
    /// normal steady state (state B), never a signal that the app is finished, so opt out
    /// **permanently** — there is no point in Orbit's lifetime at which being silently auto-quit
    /// is acceptable, which is why `enableAutomaticTermination(_:)` is never called anywhere.
    ///
    /// API: `-[NSProcessInfo disableAutomaticTermination:]` — Foundation, macOS 10.7+, verified
    /// in the installed SDK at `NSProcessInfo.h:78`. It increments a counter of automatic-quit
    /// opt-outs; while that counter is above zero the app is meant to be considered active and
    /// ineligible for automatic termination. The declarative half of the opt-out is
    /// `NSSupportsAutomaticTermination` = `<false/>` in `Info.bundle.plist`.
    ///
    /// Measured caveat, recorded rather than papered over: AppKit still logs
    /// `_kLSApplicationWouldBeTerminatedByTALKey=1` when the last window leaves the screen, with
    /// or without this call, and with or without `automaticTerminationSupportEnabled = true`
    /// (all three combinations were built and run). That flag is AppKit's own bookkeeping and
    /// does not consult this counter. What actually stopped the termination was giving the app a
    /// real background identity in state B — the window is no longer destroyed and the
    /// activation policy really becomes `.accessory` (see `isMainWindow` and `hideMainWindow`);
    /// a *foreground* app with zero windows is what the system was quitting. This call and the
    /// plist key stay as the documented belt-and-braces opt-out.
    ///
    /// *Sudden* termination is a different counter (`NSProcessInfo.h:69-70`) and is deliberately
    /// left alone — nothing in the observed logs implicates it.
    private func disableAutomaticTermination() {
        ProcessInfo.processInfo.disableAutomaticTermination(
            "Orbit stays resident in the menu bar and keeps the capture daemon running"
        )
    }

    private func configureInstalledOrbitRoot() {
        guard ProcessInfo.processInfo.environment["ORBIT_ROOT"] == nil,
              let root = OrbitPaths.defaultOrbitRoot() else { return }
        setenv("ORBIT_ROOT", root, 1)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        TelemetryService.shared.initialize(policy: CapturePolicyStorage.load())
        DaemonNotificationService.shared.configure()
        Task {
            await DaemonNotificationService.shared.requestAuthorizationIfNeeded()
        }
        registerAIFunctions()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openMainWindow),
            name: .openMainWindow,
            object: nil
        )
        // Disable NSHostingView → NSWindow intrinsic-size broadcast. On macOS 26,
        // edit-mode layout changes otherwise hit updateAnimatedWindowSize → _reallySetFrame abort.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(openMainWindow),
            name: .orbitAccessActivate,
            object: nil
        )
        // State B: closing the main window (red button) hides it and drops the Dock
        // icon instead of terminating. The daemon keeps running — capture must not stop.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mainWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
        installCloseInterceptorsOnExistingWindows()
    }

    /// Covers both launch orderings. SwiftUI may have already created and keyed the
    /// `WindowGroup` window by the time this delegate is called (in which case the
    /// `didBecomeKeyNotification` observer above missed it), or it may create it a runloop turn
    /// later (in which case the immediate pass finds nothing). Both passes are idempotent.
    private func installCloseInterceptorsOnExistingWindows() {
        for window in NSApp.windows {
            installCloseInterceptorIfNeeded(on: window)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for window in NSApp.windows {
                self.installCloseInterceptorIfNeeded(on: window)
            }
        }
    }

    @objc private func mainWindowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              Self.isMainWindow(window) else { return }
        hideMainWindow(window)
    }

    /// SwiftUI does **not** set the `WindowGroup`'s `id:` verbatim as the `NSWindow.identifier`.
    /// For `WindowGroup("orbit", id: "main")` (`OrbitAccessApp.swift:9`) the real identifier
    /// observed at runtime is **`main-AppWindow-1`** — the scene id, a suffix, and a 1-based
    /// instance number. Every `identifier?.rawValue == "main"` comparison therefore matched
    /// nothing, which is why the close button neither hid the window nor dropped the Dock icon:
    /// `hideMainWindow` was never reached at all. Match the scene-id prefix instead, and keep
    /// the bare `"main"` case in case AppKit/SwiftUI ever stops decorating it.
    private static func isMainWindow(_ window: NSWindow) -> Bool {
        guard let id = window.identifier?.rawValue else { return false }
        return id == "main" || id.hasPrefix("main-")
    }

    /// State B. Never stops the daemon — capture running while the window is away is the
    /// entire point of this state. `applicationShouldTerminateAfterLastWindowClosed` below and
    /// `disableAutomaticTermination()` above are what keep the process alive once the window is
    /// gone from the screen.
    private func hideMainWindow(_ window: NSWindow) {
        window.orderOut(nil)
        // Hand foreground status back to whatever the user switches to. Without this Orbit stays
        // the active application while showing nothing, which is exactly the state macOS treats
        // as "done" and quits on the next app switch.
        NSApp.deactivate()
        // `NSApp.deactivate()` is not synchronous, so the policy change waits for a later
        // runloop turn. `setActivationPolicy(_:)` reports whether the transition was accepted
        // ("YES if setting the activation policy is successful, and NO if not",
        // `NSApplication.h:301`), so `enterAccessoryMode` checks that Bool instead of assuming.
        DispatchQueue.main.async {
            AppDelegate.enterAccessoryMode(attemptsRemaining: 3)
        }
    }

    /// Drops the Dock icon. Retries across runloop turns because acceptance depends on Orbit
    /// having actually lost frontmost status, which is not synchronous with `NSApp.deactivate()`.
    private static func enterAccessoryMode(attemptsRemaining: Int) {
        guard NSApp.activationPolicy() != .accessory else { return }
        if NSApp.setActivationPolicy(.accessory) { return }
        guard attemptsRemaining > 1 else {
            NSLog("Orbit: setActivationPolicy(.accessory) refused; the Dock icon may remain visible")
            return
        }
        DispatchQueue.main.async {
            AppDelegate.enterAccessoryMode(attemptsRemaining: attemptsRemaining - 1)
        }
    }

    /// State B must survive the last window disappearing. AppKit's default is to terminate the
    /// process when the last window closes, which runs `applicationShouldTerminate` → the quit
    /// alert → `stopDaemon()`, collapsing state B ("closed to the menu bar, still capturing")
    /// into state C ("quit completely"). The menu-bar item is a hand-rolled `NSStatusItem`
    /// rather than a `MenuBarExtra` scene, so nothing else holds the app open either.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        // Skip status-bar popover / floating utility panels — only size-fix main app windows.
        guard window.styleMask.contains(.titled) || window.styleMask.contains(.fullSizeContentView) else {
            return
        }
        Self.disableHostingViewWindowSizing(in: window)
        installCloseInterceptorIfNeeded(on: window)
    }

    /// Installs the hide-instead-of-close delegate on the main window.
    ///
    /// `didBecomeKeyNotification` alone is not enough: SwiftUI creates *and keys* the
    /// `WindowGroup` window before this delegate's `applicationDidFinishLaunching` registers the
    /// observer, so on a cold launch the notification never arrives (confirmed at runtime — a
    /// `didBecomeKey` trace fired zero times while `willClose` fired). Hence the launch-time
    /// sweep in `installCloseInterceptorsOnExistingWindows()`; this method stays idempotent so
    /// both entry points can call it freely.
    private func installCloseInterceptorIfNeeded(on window: NSWindow) {
        guard Self.isMainWindow(window),
              !(window.delegate is MainWindowCloseInterceptor) else { return }
        let interceptor = MainWindowCloseInterceptor(
            forwardee: window.delegate,
            onHide: { [weak self] closing in self?.hideMainWindow(closing) }
        )
        window.delegate = interceptor
        closeInterceptors.append(interceptor)
    }

    /// Sets `sizingOptions = []` on every SwiftUI `NSHostingView` under `window`.
    /// Uses KVC because `NSHostingView` is generic and not directly castable from AppKit.
    private static func disableHostingViewWindowSizing(in window: NSWindow) {
        guard let root = window.contentView else { return }
        walkAndDisableSizing(root)
    }

    private static func walkAndDisableSizing(_ view: NSView) {
        let className = NSStringFromClass(type(of: view))
        if className.contains("NSHostingView"),
           view.responds(to: NSSelectorFromString("setSizingOptions:")) {
            // Empty NSHostingSizingOptions — stop intrinsic content size → window coupling.
            view.setValue(0, forKey: "sizingOptions")
        }
        for child in view.subviews {
            walkAndDisableSizing(child)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Chat history writes are queued on a background queue, so the newest turn can still be
        // in flight here. This covers every exit path: ⌘Q and the popover's quit button route
        // through `applicationShouldTerminate` → `.terminateLater`, and the
        // `NSApp.reply(toApplicationShouldTerminate: true)` that resumes termination posts
        // `willTerminateNotification`, which is what invokes this method.
        ChatHistoryStorage.flushPendingSaves()
        statusBarController?.teardown()
        InstanceLock.release()
    }

    // State C: ⌘Q and the popover's "Quit Orbit" button both call NSApp.terminate(nil),
    // which routes here. If the daemon is running, confirm before stopping it — quitting
    // also stops context capture, and that must be visible, not silent.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // `viewModel` is nil until `configureStatusBar` runs. `enforceSingleInstance()` can
        // call NSApp.terminate(nil) for a redundant second launch before that point — that
        // path must stay silent/instant, not pop a confirmation dialog.
        guard let viewModel, viewModel.isDaemonOnline else { return .terminateNow }

        // Quitting from state B is the common case — the window is closed and the user picks
        // "quit orbit" in the menu-bar popover. An `.accessory` app is not brought forward for a
        // modal alert, so `runModal()` would block on a dialog the user cannot see or reach
        // (measured: `sample` showed the app parked in `-[NSAlert runModal]` while the alert was
        // absent from the accessibility window list). Restore foreground presence for the
        // duration of the question, and put it back if the answer is Cancel — leaving a
        // windowless app in `.regular` is the state macOS quits behind the user's back.
        let wasAccessory = NSApp.activationPolicy() == .accessory
        if wasAccessory {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "quit orbit?"
        alert.informativeText = "Quitting also stops the orbit daemon — context capture will pause until you reopen the app."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            if wasAccessory {
                NSApp.deactivate()
                DispatchQueue.main.async {
                    AppDelegate.enterAccessoryMode(attemptsRemaining: 3)
                }
            }
            return .terminateCancel
        }

        Task { @MainActor in
            await viewModel.stopDaemon()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @MainActor
    func configureStatusBar(viewModel: AppViewModel) {
        guard statusBarController == nil else { return }
        self.viewModel = viewModel
        let controller = StatusBarController()
        controller.setup(viewModel: viewModel)
        statusBarController = controller
    }

    @discardableResult
    private func enforceSingleInstance() -> Bool {
        if let bundleID = Bundle.main.bundleIdentifier {
            let currentPID = ProcessInfo.processInfo.processIdentifier
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != currentPID }
            if let existing = others.first {
                existing.activate(options: [.activateAllWindows])
                DistributedNotificationCenter.default().post(name: .orbitAccessActivate, object: nil)
                NSApp.terminate(nil)
                return false
            }
        }

        if !InstanceLock.acquire() {
            DistributedNotificationCenter.default().post(name: .orbitAccessActivate, object: nil)
            NSApp.terminate(nil)
            return false
        }

        return true
    }

    @objc private func openMainWindow() {
        Task { @MainActor in
            guard let statusBarController else {
                // A second launch while this instance is in state B posts
                // `.orbitAccessActivate` and quits itself. If that lands before
                // `configureStatusBar` has run there is no controller to route through, and a
                // silent no-op would look like "launching Orbit does nothing" — so restore the
                // Dock icon and the window here too (plan 46 §1.4).
                Self.restoreMainWindow()
                return
            }
            statusBarController.openMainWindow()
        }
    }

    /// Same order as `StatusBarController.openMainWindow()`: activation policy first, or the
    /// window comes back without a Dock icon or a menu bar.
    @MainActor
    static func restoreMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where isMainWindow(window) {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }

    private func registerAIFunctions() {
        let registry = AIFunctionRegistry.shared
        for agent in AgentType.allCases {
            registry.register(AgentPromptFunction(agentType: agent))
        }
    }
}
