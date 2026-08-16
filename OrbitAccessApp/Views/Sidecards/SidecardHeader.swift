import SwiftUI

/// The plain-text header above the sidecard column: "At a glance", today's
/// date, and the edit / hide controls. No card surface — sits directly on
/// the window background, matching the reference screenshot.
struct SidecardHeader: View {
    @Environment(AppViewModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    private var isEditing: Bool { model.sidecardStore.isEditing }
    @State private var showDiscardConfirmation = false

    var body: some View {
        HStack(alignment: .top) {
            // Hidden (not removed) while editing so Discard/Save changes get the full
            // columnWidth row. Opacity-only — the parent already fixes this header's
            // width (SidecardOverlay.swift), so this cannot change measured size and
            // does not risk the NSHostingView.updateAnimatedWindowSize abort.
            VStack(alignment: .leading, spacing: 2) {
                Text("At a glance")
                    .font(.caption)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                Text(Date.now, format: .dateTime.weekday(.wide).month(.wide).day())
                    .font(.title2.weight(.semibold))
            }
            .opacity(isEditing ? 0 : 1)
            .allowsHitTesting(!isEditing)

            Spacer(minLength: 8)

            // ZStack keeps measured height/width stable across idle ↔ editing so
            // NSHostingView.updateAnimatedWindowSize does not abort (macOS 26).
            ZStack(alignment: .trailing) {
                OrbitIconButton(label: "Edit widgets", systemImage: "gearshape") {
                    model.sidecardStore.beginEditing()
                }
                .opacity(isEditing ? 0 : 1)
                .allowsHitTesting(!isEditing)

                editActions
                    .opacity(isEditing ? 1 : 0)
                    .allowsHitTesting(isEditing)
            }
            // Reserve the trailing 40pt the old in-header "Hide widgets" button (28pt wide,
            // plus a 12pt gap to the gear) used to occupy. That corner slot now belongs to
            // MainWindowView's fixed-position reveal/hide overlay (topTrailing, same
            // SidecardMetrics margins) — without this inset the gear button would expand
            // into that exact 28x28 rectangle and sit pixel-on-pixel with the overlay button.
            .padding(.trailing, 40)
        }
        .confirmationDialog(
            "Are you sure you want to discard your widget changes?",
            isPresented: $showDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) {
                model.sidecardStore.discardEditing()
            }
            Button("Keep editing", role: .cancel) {}
        }
    }

    /// Discard + Save changes on one row (columnWidth is 300pt — both labels fit).
    private var editActions: some View {
        HStack(spacing: 8) {
            discardButton
            saveButton
        }
    }

    private var discardButton: some View {
        Button("Discard") {
            showDiscardConfirmation = true
        }
        .buttonStyle(OrbitFlatButtonStyle(variant: .destructive, size: .sm))
        .keyboardShortcut(.escape)
        // Always in the ZStack for size stability; disable when idle so Escape is not stolen.
        .disabled(!isEditing)
    }

    private var saveButton: some View {
        Button("Save changes") {
            model.sidecardStore.commitEditing()
        }
        .buttonStyle(OrbitFlatButtonStyle(variant: .primary, size: .sm))
    }
}
