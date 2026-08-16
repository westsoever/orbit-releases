import AppKit
import SwiftUI

/// Root view for the ⌘, Settings scene (Plan 17 Phase 6.4). Gives `CloudAISettingsView`
/// a permanent home — it was previously only reachable from a card that disappears once
/// Cloud AI is configured — alongside the two genuinely-missing policy.json tabs.
struct OrbitSettingsView: View {
    @Environment(AppViewModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    /// Plan 53 Phase 2. Raw-string key, repeated at each site by convention.
    @AppStorage("hasCompletedTour") private var hasCompletedTour = false

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                CloudAISettingsView()
                    .environment(model)
                    .tabItem { Label("Cloud AI", systemImage: "cloud") }

                // Plan 53 Phase 6. `AccountSettingsView` used to be reachable only from the
                // bottom of the Cloud AI tab, which is no place for the account — and no place
                // to find the profile questions again after skipping them.
                AccountTabView()
                    .environment(model)
                    .tabItem { Label("Account", systemImage: "person.crop.circle") }

                CaptureTierSettingsView()
                    .tabItem { Label("Capture", systemImage: "record.circle") }

                DetectionSettingsView()
                    .tabItem { Label("Detection", systemImage: "sparkle.magnifyingglass") }

                AboutSettingsView()
                    .tabItem { Label("About", systemImage: "info.circle") }
            }
            .frame(maxHeight: .infinity)
            // Plan 53 Phase 4 — the sign-in entry point, and the only one that is always
            // reachable. It exists **only** when the feature flag is on and this Mac has no
            // cloud account: with the flag off (the default) there is no sign-in affordance
            // anywhere in the app, which is what decision D2 requires.
            if model.canOfferCloudSignIn {
                OrbitHairlineDivider()
                signInRow
                    .frame(height: 56)
                    .layoutPriority(1)
            }
            OrbitHairlineDivider()
            // Fixed height + higher layout priority: the tab content is unbounded and, left
            // to the default priority, ate the whole VStack and squeezed this row to nothing.
            showTourRow
                .frame(height: 56)
                .layoutPriority(1)
        }
        // Raised from 420: the tab content is already taller than the old ideal (the Cloud AI
        // tab clips at both edges without this), and the tour row below it needs its 56pt to
        // land inside the window rather than under its bottom edge. The sign-in row, when it
        // is there at all, needs the same 56 again.
        .frame(minWidth: 460, minHeight: model.canOfferCloudSignIn ? 697 : 640)
    }

    /// Sign in from Settings. Same shape as `showTourRow` below, and the same reason for
    /// raising the main window rather than presenting here: the sheet is owned by
    /// `MainWindowView`, so both entry points present exactly one sheet in one place.
    private var signInRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Cloud account")
                    .font(.callout)
                Text("Optional. Links this Mac to orbit's relay with a code sent to your email — no password. Your captured context is not uploaded.")
                    .font(.caption)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Sign in") {
                raiseMainWindow()
                model.showSignIn = true
            }
            .buttonStyle(OrbitFlatButtonStyle(variant: .secondary))
        }
        .padding(12)
        .background(Color.orbitCanvas(for: colorScheme))
    }

    /// Re-entry point for the onboarding tour, so skipping it is never permanent.
    /// The tour sheet is owned by `MainWindowView`, so this raises the main window and
    /// flips the model flag; `hasCompletedTour` is reset too, which is what makes the
    /// "reset the flag via Settings" path observable on the next launch as well.
    private var showTourRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Onboarding tour")
                    .font(.callout)
                Text("Five short steps on what orbit captures, how approval works, and where things are.")
                    .font(.caption)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
            }
            Spacer()
            Button("Show tour") {
                hasCompletedTour = false
                raiseMainWindow()
                model.showTour = true
            }
            .buttonStyle(OrbitFlatButtonStyle(variant: .secondary))
        }
        .padding(12)
        .background(Color.orbitCanvas(for: colorScheme))
    }

    /// Brings the *existing* main window forward. Deliberately not `openWindow(id: "main")`:
    /// that is a `WindowGroup`, so SwiftUI answers it by opening a **second** main window
    /// (verified — two windows, each presenting its own tour sheet) instead of raising the
    /// one already on screen.
    private func raiseMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let main = NSApplication.shared.windows.first {
            $0.identifier?.rawValue.hasPrefix("main") == true
        }
        main?.makeKeyAndOrderFront(nil)
    }
}
