import SwiftUI

/// Repointed in plan 53 Phase 4. It used to host `SignUpView` as a full-window sign-up
/// **wall**; Phase 1 removed the wall and this phase removes the view — its
/// `.roundedBorder`/`.borderedProminent` styling is retired with it (§0.4 anti-pattern 8).
///
/// What is left is the presentation shell for the *optional* sign-in: `MainWindowView`
/// presents this as a sheet, and Settings raises it. It is never rendered as the root of the
/// window, so there is no state in which orbit withholds itself pending an account (D2).
struct OnboardingContainerView: View {
    @Environment(AppViewModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SignInView(onSignedIn: {
            // Cloud sign-in links the *existing* local row; it does not switch users, so
            // there is nothing to reload beyond the AI state, which can now resolve the
            // relay path.
            model.refreshCloudAIState()
            offerProfileQuestions()
        })
        .background(Color.orbitCanvas(for: colorScheme).ignoresSafeArea())
    }

    /// Plan 53 Phase 6 — the questionnaire follows sign-in and nothing else. It is skipped
    /// entirely for anyone who dismissed this sheet without an account, and for anyone who has
    /// already answered (Settings › Account is the way back in).
    ///
    /// The delay is the same one `TourView.finish()` needs: SwiftUI drops a sheet raised in the
    /// same turn as another sheet's dismissal.
    private func offerProfileQuestions() {
        guard model.canOfferProfileQuestions, !ProfileAnswersStore.hasSubmitted else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            model.showProfileQuestions = true
        }
    }
}
