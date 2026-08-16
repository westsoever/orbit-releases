import SwiftUI

/// Plan 53 Phase 2 — the skippable onboarding tour.
///
/// Pure UI with zero backend: it explains what orbit does and never touches the daemon,
/// the relay, or the session. It is deliberately **not** gated on `isSignedIn` — a
/// local-only user (the default after Phase 1) is exactly the user who needs it.
///
/// Structure copies the sheet shell from `EditRoutineView` (header / hairline /
/// `ScrollView` / hairline / footer) and its footer button row. There is no step
/// component, page indicator, or `TabView(.page)` anywhere in this app, so the step
/// machinery below is a plain `@State` index plus a `ForEach` of token-styled dots.
///
/// Every factual claim in `Self.steps` is traceable to `docs/marketing-brief.md`
/// ("safe to state as fact"), `docs/capture-compatibility.md`, or shipped UI. In
/// particular the copy never claims "no telemetry", never says "fully local" without
/// the analytics caveat, never claims a notarized or Developer-ID signed build, and
/// never implies orbit can recover a lost encryption key — all four are explicitly
/// forbidden by the brief's "Explicitly excluded" section.
struct TourView: View {
    @Environment(AppViewModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    // Raw-string `@AppStorage` key repeated at each site, per the convention in
    // `OrbitAccessApp.swift` (`sidebaneVisible`, `insightVisible`, …). No key constants.
    @AppStorage("hasCompletedTour") private var hasCompletedTour = false

    @State private var step = 0

    // MARK: - Content model

    private struct Point: Identifiable {
        let id = UUID()
        let icon: String
        let text: String
    }

    private struct Step: Identifiable {
        let id: Int
        let eyebrow: String
        let title: String
        let subtitle: String
        let points: [Point]
        let footnote: String?
    }

    private static let steps: [Step] = [
        Step(
            id: 0,
            eyebrow: "WHAT ORBIT DOES",
            title: "It sees what you did — and knows what you want",
            subtitle: "orbit is an always-on assistant for macOS. It captures your working context, keeps it on this Mac, and dispatches approved work to a model.",
            points: [
                Point(
                    icon: "eye.slash",
                    text: "Text only. orbit reads window and UI text through the macOS Accessibility API. It does not take screenshots and does not record your screen."
                ),
                Point(
                    icon: "internaldrive",
                    text: "Captured content stays on this device — screen text, chat, search and tasks are stored in a local database and are not uploaded."
                ),
                Point(
                    icon: "lock.fill",
                    text: "That database is encrypted at rest. The key lives in your macOS Keychain, never in a plaintext config file."
                ),
                Point(
                    icon: "chart.bar",
                    text: "Usage analytics and crash reports are on by default. They carry structural metadata only — which feature was used, a crash stack trace — never captured text. Turn them off in Settings › Capture."
                ),
            ],
            footnote: "orbit is early beta. The install flow is built for testers, not yet for a polished consumer launch."
        ),
        Step(
            id: 1,
            eyebrow: "HOW CAPTURE WORKS",
            title: "Selective, event-driven, and yours to switch off",
            subtitle: "Capture is triggered by window and app switches — it is not a continuous recording, and it is not one setting but a set of tiers you control.",
            points: [
                Point(
                    icon: "bolt",
                    text: "Event-driven. orbit wakes on a window or app switch, reads what is on screen, and goes back to sleep. Nothing runs on a loop in between."
                ),
                Point(
                    icon: "puzzlepiece.extension",
                    text: "Most apps are read straight through the Accessibility API. Browsers often expose nothing that way, so they need the browser companion — or the OCR fallback, which is off until you enable it."
                ),
                Point(
                    icon: "folder",
                    text: "File activity is its own opt-in tier. When enabled it records create, modify and delete events under the folders you choose — paths only, never file contents."
                ),
                Point(
                    icon: "hand.raised",
                    text: "Excluded apps are never read. Password managers ship excluded by default, and you can add any app under Privacy & setup — or pause capture entirely."
                ),
                Point(
                    icon: "clock.arrow.circlepath",
                    text: "Captured events are purged automatically once they pass the retention window you set in Settings › Capture."
                ),
            ],
            footnote: nil
        ),
        Step(
            id: 2,
            eyebrow: "THE APPROVAL GATE",
            title: "orbit proposes. You approve. Nothing runs on its own",
            subtitle: "Detected work waits for you. An agent never executes anything you have not explicitly approved.",
            points: [
                Point(
                    icon: "sparkle.magnifyingglass",
                    text: "orbit reads your context and surfaces the work it thinks it spotted into the Detected column."
                ),
                Point(
                    icon: "checkmark.circle",
                    text: "You approve, or you skip. A detected task sits there until you decide — approving it is what moves it to an agent."
                ),
                Point(
                    icon: "list.bullet.rectangle",
                    text: "Every dispatch is written to orbit's local audit log, so what an agent did is auditable after the fact."
                ),
                Point(
                    icon: "arrow.uturn.backward",
                    text: "The board keeps the outcome: Detected, Approved, Done, Failed, Skipped. Nothing disappears silently."
                ),
            ],
            footnote: nil
        ),
        Step(
            id: 3,
            eyebrow: "WHERE THINGS ARE",
            title: "Five places, and that is the whole app",
            subtitle: "The left sidebar switches the main pane; the right side holds widgets. ⌘S toggles the sidebar, ⌘B the widgets.",
            points: [
                Point(
                    icon: "bubble.left.and.bubble.right",
                    text: "Chat — the default pane. Ask about what you were doing and orbit answers from your saved context. ⌘N starts a new chat."
                ),
                Point(
                    icon: "magnifyingglass",
                    text: "Search — the same box. Before you connect a model it searches your saved context by keyword instead of answering."
                ),
                Point(
                    icon: "square.grid.2x2",
                    text: "Tasks — the board where detected work waits for your approval."
                ),
                Point(
                    icon: "calendar",
                    text: "Timeline — what you actually worked on, in order, reconstructed from captured context."
                ),
                Point(
                    icon: "gearshape",
                    text: "Settings — ⌘, for Cloud AI, Capture, Detection and About. Privacy & setup sits at the foot of the sidebar: pause, exclude, forget the last few minutes, export or delete everything."
                ),
            ],
            footnote: nil
        ),
        Step(
            id: 4,
            eyebrow: "WHAT TO TRY FIRST",
            title: "Five things, in this order",
            subtitle: "orbit is only as useful as the context it has, so the first step is simply to leave it running.",
            points: [
                Point(
                    icon: "play.circle",
                    text: "Work normally for an hour. orbit needs captured context before anything it says is worth reading."
                ),
                Point(
                    icon: "cpu",
                    text: "Connect a model in Settings. A local Ollama model runs entirely on your Mac and is the privacy-preserving option; you can also bring your own OpenRouter key, or use hosted Cloud AI."
                ),
                Point(
                    icon: "bubble.left",
                    text: "Ask the chat what you were working on this morning, then follow up. That is the fastest way to see whether the context is landing."
                ),
                Point(
                    icon: "checklist",
                    text: "Open Tasks and approve one detected item — that is the whole loop, end to end."
                ),
                Point(
                    icon: "shield",
                    text: "Skim Privacy & setup once. Knowing where pause, exclusions and delete-everything live is worth the minute."
                ),
            ],
            footnote: "You can reopen this tour any time from Settings."
        ),
    ]

    private var current: Step { Self.steps[step] }
    private var isLastStep: Bool { step == Self.steps.count - 1 }

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
        .frame(minWidth: 620, idealWidth: 660, minHeight: 480, idealHeight: 540)
        .background(Color.orbitCanvas(for: colorScheme))
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Welcome to orbit")
                    .font(.headline)
                Text("Step \(step + 1) of \(Self.steps.count) — you can leave at any point.")
                    .font(.caption)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
            }
            Spacer()
            // Closing is a skip, not a "come back later" — otherwise the tour would
            // re-present on every launch. There is deliberately no confirm step.
            OrbitIconButton(label: "Skip the tour", systemImage: "xmark", variant: .ghost, size: .sm) {
                skip()
            }
            .keyboardShortcut(.escape)
        }
        .padding(16)
    }

    // MARK: - Step content

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: current.eyebrow)
                Text(current.title)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(current.subtitle)
                    .font(.callout)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            OrbitCard(accent: .orbitAccent(for: colorScheme)) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(current.points) { point in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: point.icon)
                                .font(.body.weight(.medium))
                                .foregroundStyle(Color.orbitAccent(for: colorScheme))
                                .frame(width: 22, alignment: .center)
                            Text(point.text)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }

            if let footnote = current.footnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(OrbitMotion.fade, value: step)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            // On every step, per Phase 2's "no step is un-skippable" guard.
            Button("Skip tour") {
                skip()
            }
            .buttonStyle(OrbitFlatButtonStyle(variant: .ghost))

            Spacer()

            stepDots

            Spacer()

            if step > 0 {
                Button("Back") {
                    withAnimation(OrbitMotion.selection) { step -= 1 }
                }
                .buttonStyle(OrbitFlatButtonStyle(variant: .ghost))
            }

            Button(isLastStep ? "Done" : "Next") {
                if isLastStep {
                    finish()
                } else {
                    withAnimation(OrbitMotion.selection) { step += 1 }
                }
            }
            // `OrbitFlatButtonStyle`'s `.primary` non-icon variant stretches to
            // `maxWidth: .infinity`, so it needs an explicit width in a row like this —
            // same treatment as `EditRoutineView`'s save button.
            .buttonStyle(OrbitFlatButtonStyle(variant: .primary))
            .frame(width: 120)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(Self.steps) { entry in
                let isCurrent = entry.id == step
                RoundedRectangle(cornerRadius: OrbitShape.radiusChip)
                    .fill(isCurrent ? Color.orbitAccent(for: colorScheme) : Color.orbitTrack(for: colorScheme))
                    .frame(width: isCurrent ? 18 : 6, height: 6)
            }
        }
        .animation(OrbitMotion.selection, value: step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step + 1) of \(Self.steps.count)")
    }

    // MARK: - Actions

    private func skip() {
        hasCompletedTour = true
        dismiss()
    }

    private func finish() {
        hasCompletedTour = true
        dismiss()
        // Plan 53 Phase 4 — offer the optional account once, to someone who has just read
        // what orbit is. Only on "Done": a user who skipped the tour has said they want to
        // be left alone, and `canOfferCloudSignIn` is false unless the feature flag is on
        // and this Mac has no cloud account yet. It is an offer, not a gate — the sheet's
        // "Continue without an account" is one click on either step.
        guard model.canOfferCloudSignIn else { return }
        Task { @MainActor in
            // SwiftUI drops a sheet raised in the same turn as another sheet's dismissal,
            // so the flag flip waits for the dismiss animation to finish.
            try? await Task.sleep(nanoseconds: 500_000_000)
            model.showSignIn = true
        }
    }
}
