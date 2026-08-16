import SwiftUI

/// Plan 53 Phase 6 — the optional profile questionnaire.
///
/// Shown **only after a successful sign-in**, and only reachable again from Settings ›
/// Account while this Mac has a cloud account. The answers sync to the relay and live nowhere
/// else, so asking a local-only user would collect data with nowhere to go and no consent
/// record — the phase's first anti-pattern guard.
///
/// Three properties are load-bearing and should survive any redesign:
///
/// 1. **No question is mandatory.** Tapping a selected chip clears it; "Save answers" is
///    enabled with everything blank.
/// 2. **Consent is separate.** The checkbox below is its own decision, worded plainly, and is
///    *not* the privacy-policy acceptance. Bundled consent is not freely given — that is the
///    GDPR failure mode this design exists to avoid. Unticked, `submit()` is never called and
///    nothing leaves the Mac; the relay rejects a consent-less body as a second line of defence.
/// 3. **Withdrawable.** Once answers exist, the footer offers deleting them, which erases the
///    relay row (`DELETE /v1/profile`) and the local copy.
///
/// Structure copies the sheet shell from `EditRoutineView` (header / hairline / `ScrollView` /
/// hairline / footer) and the selectable-chip idiom from its `dayChips` (`:236-255`) — same
/// `OrbitShape.radiusChip` background swap between `Color.orbitAccent(for:)` and
/// `Color.orbitSurfaceMuted`, widened for text labels and wrapped with the existing
/// `FlowLayout`.
struct ProfileQuestionsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var answers = ProfileAnswers()
    @State private var consentGiven = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var hasStoredAnswers = false

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
        .frame(minWidth: 620, idealWidth: 660, minHeight: 520, idealHeight: 580)
        .background(Color.orbitCanvas(for: colorScheme))
        .onAppear {
            // Resumable: re-opening shows what was sent last time rather than a blank form.
            if let stored = ProfileAnswersStore.load() {
                answers = stored
                hasStoredAnswers = true
                // Consent is re-asked every time rather than restored from disk. A tick that
                // the user cannot see themselves make is not a consent record.
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("A few optional questions")
                    .font(.headline)
                Text("All of these can be skipped. They help us understand who orbit is for — they do not change how the app behaves.")
                    .font(.caption)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            OrbitIconButton(
                label: "Skip these questions",
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

    // MARK: - Questions

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            question(
                title: "Highest degree",
                options: ProfileQuestionnaire.degreeOptions,
                selection: $answers.degree
            )
            question(
                title: "Position",
                options: ProfileQuestionnaire.positionOptions,
                selection: $answers.position
            )
            question(
                title: "Function",
                options: ProfileQuestionnaire.functionOptions,
                selection: $answers.function
            )
            question(
                title: "Area",
                options: ProfileQuestionnaire.areaOptions,
                selection: $answers.area
            )
            otherQuestion
            consentCard

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(Color.orbitScoreRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func question(
        title: String,
        options: [String],
        selection: Binding<String?>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                if selection.wrappedValue != nil {
                    Button("Clear") {
                        selection.wrappedValue = nil
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            FlowLayout(spacing: 6) {
                ForEach(options, id: \.self) { option in
                    chip(option, isSelected: selection.wrappedValue == option) {
                        // Tapping the selected chip clears it — that is what makes "no
                        // question is mandatory" true after a mis-tap, not just before one.
                        selection.wrappedValue = selection.wrappedValue == option ? nil : option
                    }
                }
            }
        }
    }

    private func chip(_ label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    isSelected ? Color.orbitAccent(for: colorScheme) : Color.orbitSurfaceMuted(for: colorScheme),
                    in: RoundedRectangle(cornerRadius: OrbitShape.radiusChip)
                )
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var otherQuestion: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Anything else")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
            TextEditor(text: $answers.other)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 80)
                .orbitCardChrome(colorScheme: colorScheme)
            Text("Free text — anything about your work that would help us shape orbit. Please leave out anything you would not want stored on our servers.")
                .font(.caption2)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Consent

    /// Deliberately its own card, its own sentence, and its own decision — never folded into
    /// accepting the privacy policy or into the sign-in step before it.
    private var consentCard: some View {
        OrbitCard(accent: .orbitAccent(for: colorScheme)) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $consentGiven) {
                    Text("Store my answers on orbit's servers")
                        .font(.callout.weight(.medium))
                }
                .toggleStyle(.checkbox)

                Text("Your answers are sent to orbit's relay and stored with your account so we can understand who uses orbit. They are not used for advertising, not sold, and not shared. You can change or delete them at any time from Settings › Account. Nothing is sent unless this box is ticked.")
                    .font(.caption)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)

                Text("Recorded against privacy policy version \(ProfileQuestionnaire.policyVersion).")
                    .font(.caption2)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button(hasStoredAnswers ? "Close" : "Skip") {
                dismiss()
            }
            .buttonStyle(OrbitFlatButtonStyle(variant: .ghost))
            .disabled(isSubmitting)

            if hasStoredAnswers {
                Button("Delete my answers") {
                    withdraw()
                }
                .buttonStyle(OrbitFlatButtonStyle(variant: .destructive))
                .disabled(isSubmitting)
            }

            Spacer()

            if !consentGiven {
                Text("Tick the box above to send.")
                    .font(.caption)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
            }

            Button(action: submit) {
                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Save answers")
                }
            }
            // `OrbitFlatButtonStyle`'s `.primary` non-icon variant stretches to
            // `maxWidth: .infinity`, so it needs an explicit width in a row like this.
            .buttonStyle(OrbitFlatButtonStyle(variant: .primary))
            .frame(width: 140)
            .disabled(isSubmitting || !consentGiven)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: - Actions

    private func submit() {
        // Belt and braces: the button is disabled without consent, and the relay rejects a
        // body without it. This is the third check, and the one that guarantees no request is
        // even built.
        guard consentGiven else { return }
        let submitted = answers
        isSubmitting = true
        errorMessage = nil
        Task { @MainActor in
            defer { isSubmitting = false }
            do {
                try await ProfileRelayClient.shared.submit(
                    submitted,
                    consent: true,
                    policyVersion: ProfileQuestionnaire.policyVersion
                )
                ProfileAnswersStore.save(
                    submitted,
                    policyVersion: ProfileQuestionnaire.policyVersion,
                    consentAt: Date()
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func withdraw() {
        isSubmitting = true
        errorMessage = nil
        Task { @MainActor in
            defer { isSubmitting = false }
            do {
                try await ProfileRelayClient.shared.withdraw()
                ProfileAnswersStore.clear()
                answers = ProfileAnswers()
                consentGiven = false
                hasStoredAnswers = false
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
