import AppKit
import SwiftUI

/// Plan 53 Phase 6 — Settings › Account.
///
/// Until this tab existed the only account UI in the app was `AccountSettingsView`, buried at
/// the bottom of the Cloud AI tab, which made "come back and answer the profile questions
/// later" impossible to find. The tab hosts that existing view unchanged and adds the
/// questionnaire re-entry point beside it, so skipping the questions is never permanent — the
/// same reasoning as the "Show tour" row.
struct AccountTabView: View {
    @Environment(AppViewModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AccountSettingsView()
                .environment(model)

            if model.canOfferProfileQuestions {
                OrbitHairlineDivider()
                profileSection
            }

            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: 420, alignment: .leading)
        .background(Color.orbitCanvas(for: colorScheme))
    }

    /// Present only with a cloud account: the answers sync to the relay and nowhere else, so
    /// there is nothing to offer a local-only Mac.
    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Profile questions")
                .font(.headline)

            Text(
                ProfileAnswersStore.hasSubmitted
                    ? "You answered a few optional questions about your background. You can change them, or delete them entirely, at any time."
                    : "Four optional questions about your background — degree, position, function, area — plus anything else you want to tell us. Nothing is sent unless you tick the consent box."
            )
            .font(.caption)
            .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
            .fixedSize(horizontal: false, vertical: true)

            Button(ProfileAnswersStore.hasSubmitted ? "Update answers" : "Answer questions") {
                raiseMainWindow()
                model.showProfileQuestions = true
            }
            .buttonStyle(OrbitFlatButtonStyle(variant: .secondary))
        }
    }

    /// Same reason as `OrbitSettingsView.raiseMainWindow()`: the sheet is owned by
    /// `MainWindowView`, and `openWindow(id: "main")` would open a *second* main window.
    private func raiseMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let main = NSApplication.shared.windows.first {
            $0.identifier?.rawValue.hasPrefix("main") == true
        }
        main?.makeKeyAndOrderFront(nil)
    }
}
