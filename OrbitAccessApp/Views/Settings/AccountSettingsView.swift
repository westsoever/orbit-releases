import SwiftUI

struct AccountSettingsView: View {
    @Environment(AppViewModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Account")
                .font(.headline)

            if let user = UserSessionService.shared.currentUser {
                LabeledContent("Name") {
                    Text(user.displayName)
                }
                LabeledContent("Email") {
                    Text(user.email)
                }
            } else if let session = UserSessionService.shared.currentSession {
                LabeledContent("Email") {
                    Text(session.email)
                }
            }

            Button("Sign out", role: .destructive) {
                Task { await model.signOut() }
            }
            .disabled(!UserSessionService.shared.isSignedIn)

            Text("Signing out stops capture and clears your session. Your context data remains on this Mac.")
                .font(.caption)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
        }
        .padding()
        .frame(maxWidth: 360, alignment: .leading)
        .background(Color.orbitCanvas(for: colorScheme))
    }
}
