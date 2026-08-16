import SwiftUI

/// Plan 53 Phase 4 — the optional cloud sign-in.
///
/// Two steps: type an email, then type the 6-digit code the relay mails back. Decision D5
/// makes the code **typed**, not opened from a link: the email is usually read on a phone
/// while orbit runs on a Mac, and a custom URL scheme on an ad-hoc-signed sandboxed app is
/// unpredictable. There is deliberately no `CFBundleURLTypes` and no `onOpenURL` anywhere.
///
/// Decision D2 makes the account **optional**, and this view is where that is enforced in
/// the UI: "Continue without an account" is present on *both* steps, and taking it leaves a
/// fully working local-only orbit. Nothing here gates capture, chat, search, tasks or the
/// tour. The whole view is unreachable unless `UserAuthService.isCloudAuthEnabled` is on
/// (default off, D4/R5).
///
/// Styling copies `CloudAIEnableCard`: `orbitCardChrome` around the body, the plain
/// `TextField` + `orbitHairlineBorder` field (`:89-103`), the spinner-inside-the-button
/// submit idiom (`:44-54`, `:142-166`) and the `.caption` + `Color.orbitScoreRed` error
/// line (`:62-66`). Deliberately **not** `SignUpView`, which used the system
/// `.roundedBorder`/`.borderedProminent` styles that Phase 4 retires (§0.4 anti-pattern 8).
struct SignInView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    private enum Step {
        case email
        case code
    }

    @State private var step: Step = .email
    @State private var email = ""
    @State private var code = ""
    @State private var sentToEmail = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var noticeMessage: String?

    /// Called after the local `users` row has been linked to the cloud account. The sheet
    /// dismisses itself either way; this is for the presenter to refresh anything derived.
    var onSignedIn: (() -> Void)?

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            OrbitHairlineDivider()
            ScrollView {
                content
                    .padding(16)
            }
            OrbitHairlineDivider()
            footer
        }
        .frame(minWidth: 460, idealWidth: 500, minHeight: 400, idealHeight: 440)
        .background(Color.orbitCanvas(for: colorScheme))
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sign in to orbit")
                    .font(.headline)
                Text("Optional. orbit already works on this Mac without an account.")
                    .font(.caption)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
            }
            Spacer()
            OrbitIconButton(
                label: "Continue without an account",
                systemImage: "xmark",
                variant: .ghost,
                size: .sm
            ) {
                dismiss()
            }
            .keyboardShortcut(.escape)
        }
        .padding(16)
    }

    // MARK: - Step content

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: step == .email ? "STEP 1 OF 2" : "STEP 2 OF 2")
                Text(step == .email ? "What is your email?" : "Enter the 6-digit code")
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            card

            Text("An account links this Mac to orbit's relay so hosted Cloud AI and cross-device identity work. Your captured context is not uploaded by signing in.")
                .font(.caption)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(OrbitMotion.fade, value: step)
    }

    private var subtitle: String {
        switch step {
        case .email:
            return "We will email you a 6-digit code. There is no password to choose or remember."
        case .code:
            return "Sent to \(sentToEmail). Codes expire, so if it has been a while just send a new one."
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch step {
            case .email:
                emailField
            case .code:
                codeField
            }

            HStack(spacing: 12) {
                Button(action: submit) {
                    if isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(step == .email ? "Send code" : "Sign in")
                    }
                }
                .buttonStyle(OrbitFlatButtonStyle(variant: .primary))
                .frame(width: 140)
                .disabled(isSubmitting || !canSubmit)
                .keyboardShortcut(.defaultAction)

                if step == .code {
                    Button("Resend code") {
                        resendCode()
                    }
                    .buttonStyle(OrbitFlatButtonStyle(variant: .secondary))
                    .disabled(isSubmitting)

                    Button("Use another email") {
                        withAnimation(OrbitMotion.fade) {
                            step = .email
                            code = ""
                            errorMessage = nil
                            noticeMessage = nil
                        }
                    }
                    .buttonStyle(OrbitFlatButtonStyle(variant: .ghost))
                    .disabled(isSubmitting)
                }
            }

            if let noticeMessage {
                Text(noticeMessage)
                    .font(.caption)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(Color.orbitScoreRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .orbitCardChrome(colorScheme: colorScheme)
    }

    private var emailField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Email")
                .font(.caption.weight(.medium))
            TextField("you@example.com", text: $email)
                .textFieldStyle(.plain)
                .font(.callout)
                .textContentType(.emailAddress)
                .padding(10)
                .background(Color.clear, in: RoundedRectangle(cornerRadius: OrbitShape.radiusControl))
                .orbitHairlineBorder(cornerRadius: OrbitShape.radiusControl, colorScheme: colorScheme)
                .disabled(isSubmitting)
        }
    }

    private var codeField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("6-digit code")
                .font(.caption.weight(.medium))
            TextField("000000", text: $code)
                .textFieldStyle(.plain)
                .font(.title3.monospacedDigit())
                .padding(10)
                .background(Color.clear, in: RoundedRectangle(cornerRadius: OrbitShape.radiusControl))
                .orbitHairlineBorder(cornerRadius: OrbitShape.radiusControl, colorScheme: colorScheme)
                .disabled(isSubmitting)
                // Paste from an email client routinely brings spaces or a stray newline
                // with it, and the relay compares the code exactly.
                .onChange(of: code) { _, newValue in
                    let digits = String(newValue.filter(\.isNumber).prefix(6))
                    if digits != newValue {
                        code = digits
                    }
                }
        }
    }

    // MARK: - Footer

    /// Present on **both** steps, per D2: leaving here must always be one click, and must
    /// leave a fully working local-only app behind.
    private var footer: some View {
        HStack(spacing: 12) {
            Button("Continue without an account") {
                dismiss()
            }
            .buttonStyle(OrbitFlatButtonStyle(variant: .ghost))
            .disabled(isSubmitting)

            Spacer()

            Text("orbit keeps capturing either way.")
                .font(.caption)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
        }
        .padding(16)
    }

    // MARK: - Actions

    private var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var canSubmit: Bool {
        switch step {
        case .email:
            return trimmedEmail.contains("@") && trimmedEmail.count >= 3
        case .code:
            return code.count == 6
        }
    }

    private func submit() {
        switch step {
        case .email:
            sendCode(advancing: true)
        case .code:
            verifyCode()
        }
    }

    private func resendCode() {
        sendCode(advancing: false)
    }

    private func sendCode(advancing: Bool) {
        let address = trimmedEmail
        isSubmitting = true
        errorMessage = nil
        noticeMessage = nil
        Task { @MainActor in
            defer { isSubmitting = false }
            do {
                try await UserAuthService.shared.requestMagicLink(email: address)
                sentToEmail = address
                // The relay answers 202 for known *and* unknown addresses on purpose, so
                // this copy must not imply the account exists.
                noticeMessage = "If that address can receive mail, a code is on its way."
                if advancing {
                    withAnimation(OrbitMotion.fade) { step = .code }
                }
            } catch {
                errorMessage = ChatErrorFormatter.signInMessage(for: error)
            }
        }
    }

    private func verifyCode() {
        let address = sentToEmail.isEmpty ? trimmedEmail : sentToEmail
        let typedCode = code
        isSubmitting = true
        errorMessage = nil
        noticeMessage = nil
        Task { @MainActor in
            defer { isSubmitting = false }
            do {
                let cloudUserId = try await UserAuthService.shared.verifyMagicLink(
                    email: address,
                    code: typedCode
                )
                // The cloud id is worth nothing until it is on the local row: that column
                // is the single definition of "has a cloud account" (§0.5A). If this half
                // fails the sheet stays open with the error, rather than silently claiming
                // a sign-in the database does not know about.
                try await UserSessionService.shared.linkCloudAccount(cloudUserId: cloudUserId)
                onSignedIn?()
                dismiss()
            } catch {
                errorMessage = ChatErrorFormatter.signInMessage(for: error)
            }
        }
    }
}
