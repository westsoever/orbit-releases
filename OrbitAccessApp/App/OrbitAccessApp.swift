import SwiftUI

@main
struct OrbitAccessApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppViewModel()

    var body: some Scene {
        WindowGroup("orbit", id: "main") {
            // Plan 53 Phase 1: no sign-up wall. The daemon mints a local-only identity
            // on startup, so there is never a signed-out state to gate the product on —
            // the window opens straight into it. `OnboardingContainerView` stays on disk
            // for Phase 4, which replaces its contents with the optional sign-in.
            MainWindowView()
                .environment(model)
                .task {
                    await model.start()
                    appDelegate.configureStatusBar(viewModel: model)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 740)
        .commands {
            NewChatCommands(model: model)
            SidebarToggleCommands(model: model)
        }

        Window("orbit chat", id: "floating-chat") {
            FloatingChatView()
                .environment(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        Settings {
            OrbitSettingsView()
                .environment(model)
        }
    }
}

/// `replacing: .newItem` displaces SwiftUI's auto-generated "New Window" item, which
/// otherwise also claims ⌘N. The model is passed in because Scene-level `Commands` sit
/// outside the WindowGroup's view hierarchy, so `@Environment(AppViewModel.self)` is
/// unavailable here.
private struct NewChatCommands: Commands {
    let model: AppViewModel

    @AppStorage("mainContentMode") private var mainContentMode: MainContentMode = .chat

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat") {
                model.chatStore.newConversation()
                mainContentMode = .chat
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(model.chatStore.isStreaming)
        }
    }
}

private struct SidebarToggleCommands: Commands {
    let model: AppViewModel

    @AppStorage("sidebaneVisible") private var sidebaneVisible = true
    @AppStorage("insightVisible") private var insightVisible = true
    @AppStorage("mainContentMode") private var mainContentMode: MainContentMode = .chat

    /// The Sidecard is force-hidden on any non-chat mode (`MainWindowView.isSidecardVisible`
    /// — `insightVisible && mainContentMode == .chat`), so the widget commands are disabled
    /// there rather than left as silent no-ops. Checking `!= .chat` (not an enumerated
    /// allowlist of non-chat cases) so this stays correct as new modes are added — Plan 17
    /// Phase 6.2 added `.timeline` after this guard was first written for `.tasks` alone, and
    /// Plan 44 item 6 confirmed `.insights` is covered the same way, with no code change
    /// needed, for the identical reason. This gates ⌘B (Hide/Show Widgets) on its own — see
    /// `editWidgetsDisabled` below for ⌘E's additional condition.
    private var widgetCommandsDisabled: Bool {
        mainContentMode != .chat
    }

    /// ⌘E (Edit/Save Widget Changes) additionally requires the Sidecard to actually be
    /// visible: `beginEditing()` on a hidden Sidecard would strand the user in an edit mode
    /// they only discover after manually re-showing the pane. This must NOT be folded into
    /// `widgetCommandsDisabled` itself, because that predicate also gates ⌘B — and ⌘B's whole
    /// job is to flip `insightVisible` back on when it's off. Disabling ⌘B whenever the pane
    /// is hidden would make it impossible to ever re-show the pane via keyboard/menu, which is
    /// a regression, not a fix.
    private var editWidgetsDisabled: Bool {
        widgetCommandsDisabled || !insightVisible
    }

    var body: some Commands {
        CommandGroup(replacing: .sidebar) {
            Button("Toggle Left Sidebar") { sidebaneVisible.toggle() }
                .keyboardShortcut("s", modifiers: .command)
            Button(insightVisible ? "Hide Widgets" : "Show Widgets") { insightVisible.toggle() }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(widgetCommandsDisabled)
            Button(model.sidecardStore.isEditing ? "Save Widget Changes" : "Edit Widgets") {
                if model.sidecardStore.isEditing {
                    model.sidecardStore.commitEditing()
                } else {
                    model.sidecardStore.beginEditing()
                }
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(editWidgetsDisabled)
        }
    }
}
