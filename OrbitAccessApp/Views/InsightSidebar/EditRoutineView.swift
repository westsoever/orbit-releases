import SwiftUI

struct EditRoutineView: View {
    @Environment(AppViewModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    let isNew: Bool
    @State private var draft: RoutineBlock
    @State private var confirmDelete = false
    @State private var timeDate: Date
    @State private var validationError: String?
    /// Ollama tags from Plan 24 `fetchLocalModels()`; empty → free-text fallback.
    @State private var availableModels: [String] = []
    @State private var modelsFetchAttempted = false

    init(routine: RoutineBlock, isNew: Bool) {
        self.isNew = isNew
        _draft = State(initialValue: routine)
        _timeDate = State(initialValue: RoutineSchedule.parseClock(routine.time, on: Date()) ?? Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            OrbitHairlineDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryCard
                    HStack(alignment: .top, spacing: 20) {
                        leftColumn
                            .frame(maxWidth: .infinity, alignment: .leading)
                        rightColumn
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
            OrbitHairlineDivider()
            footer
        }
        .frame(minWidth: 720, idealWidth: 760, minHeight: 520, idealHeight: 560)
        .background(Color.orbitCanvas(for: colorScheme))
        .confirmationDialog(
            "Delete this routine?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete routine", role: .destructive) {
                model.insightStore.delete(id: draft.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the routine from your local list. It cannot be undone.")
        }
        .onChange(of: timeDate) { _, newValue in
            draft.time = Self.formatHHMM(newValue)
        }
        // Hydrate local model list via Plan 24 RPC (same helper as CloudAISettingsView).
        .task { await hydrateLocalModels() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(isNew ? "Create routine" : "Edit routine")
                    .font(.headline)
                Text(
                    isNew
                        ? "Set the details, then create the routine."
                        : "Adjust the details, then save the routine."
                )
                .font(.caption)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
            }
            Spacer()
            OrbitIconButton(label: "Close without saving", systemImage: "xmark", variant: .ghost, size: .sm) {
                dismiss()
            }
            .keyboardShortcut(.escape)
        }
        .padding(16)
    }

    // MARK: - Summary

    private var summaryCard: some View {
        OrbitCard {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                    .frame(width: 28, height: 28)
                    .background(Color.orbitSurfaceMuted(for: colorScheme), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.title.isEmpty ? "Untitled routine" : draft.title)
                        .font(.callout.weight(.semibold))
                        .kerning(-0.1)
                    Text(RoutineSchedule.scheduleSummary(draft))
                        .font(.caption2)
                        .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                }
                Spacer(minLength: 8)
                statusBadges
            }
        }
    }

    @ViewBuilder
    private var statusBadges: some View {
        let now = Date()
        if draft.runState == .running {
            Text("Running")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.orbitScoreEmerald)
        } else if draft.isCompletedToday(now: now) {
            Text("Done today")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
        } else if draft.isActive(now: now) {
            Text("Active")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.orbitScoreEmerald)
        }
    }

    // MARK: - Left column

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                TextField("Routine name", text: $draft.title)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Schedule")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))

                Picker("Frequency", selection: $draft.frequency) {
                    ForEach(RoutineFrequency.allCases, id: \.self) { freq in
                        Text(freq.displayName).tag(freq)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if draft.frequency == .weekly {
                    dayChips
                } else if draft.frequency == .monthly {
                    HStack {
                        Text("Day of month")
                            .font(.caption)
                            .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                        Spacer()
                        Stepper(value: $draft.monthDay, in: 1...31) {
                            Text("\(draft.monthDay)")
                                .font(.callout.monospacedDigit())
                                .frame(minWidth: 24, alignment: .trailing)
                        }
                        .frame(maxWidth: 160)
                    }
                }

                DatePicker(
                    "Time",
                    selection: $timeDate,
                    displayedComponents: .hourAndMinute
                )
                .labelsHidden()
                .datePickerStyle(.compact)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Model")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                if modelsFetchAttempted && !availableModels.isEmpty {
                    Picker("Model", selection: $draft.model) {
                        Text("App default").tag(String?.none)
                        ForEach(menuModelTags, id: \.self) { name in
                            Text(name).tag(Optional.some(name))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                } else if modelsFetchAttempted {
                    TextField("Model tag (optional)", text: modelFreeTextBinding)
                        .textFieldStyle(.roundedBorder)
                    Text("Ollama is unreachable — enter a model tag or leave blank for the app default.")
                        .font(.caption2)
                        .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            OrbitCard {
                VStack(spacing: 12) {
                    Toggle(isOn: $draft.notifyOnReady) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Notifications")
                                .font(.callout.weight(.medium))
                            Text("Push when a new report is ready.")
                                .font(.caption2)
                                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                        }
                    }
                    .toggleStyle(.switch)

                    Toggle(isOn: $draft.emailOnReady) {
                        Text("Email")
                            .font(.callout.weight(.medium))
                    }
                    .toggleStyle(.switch)
                }
            }

            if let validationError {
                Text(validationError)
                    .font(.caption2)
                    .foregroundStyle(Color.orbitScoreRed)
            }
        }
    }

    private var dayChips: some View {
        HStack(spacing: 6) {
            ForEach(1...7, id: \.self) { day in
                let selected = draft.weekdays.contains(day)
                Button {
                    toggleWeekday(day)
                } label: {
                    Text(RoutineSchedule.dayChipLabels[day - 1])
                        .font(.caption2.weight(.semibold))
                        .frame(width: 32, height: 32)
                        .background(
                            selected ? Color.orbitAccent(for: colorScheme) : Color.orbitSurfaceMuted(for: colorScheme),
                            in: RoundedRectangle(cornerRadius: OrbitShape.radiusChip)
                        )
                        .foregroundStyle(selected ? .white : .primary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Right column

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Instructions")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                Text("Describe what you'd like orbit to gather, analyze, or summarize.")
                    .font(.caption2)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
            }

            ZStack(alignment: .bottomTrailing) {
                TextEditor(text: $draft.instructions)
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 220)
                    .orbitCardChrome(colorScheme: colorScheme)

                OrbitIconButton(label: "Voice input (coming soon)", systemImage: "mic.fill", variant: .ghost, size: .sm, isDisabled: true) {}
                    .padding(6)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if !isNew {
                Button("Delete") {
                    confirmDelete = true
                }
                .buttonStyle(OrbitFlatButtonStyle(variant: .destructive))
            }
            Spacer()
            Button("Cancel") {
                dismiss()
            }
            .buttonStyle(OrbitFlatButtonStyle(variant: .ghost))

            Button(isNew ? "Create routine" : "Save changes") {
                save()
            }
            .buttonStyle(OrbitFlatButtonStyle(variant: .primary))
            .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .frame(width: 140)
        }
        .padding(16)
    }

    // MARK: - Model picker

    /// Installed tags plus a saved selection that is no longer in the list (keeps the menu honest).
    private var menuModelTags: [String] {
        guard let selected = draft.model, !availableModels.contains(selected) else {
            return availableModels
        }
        return availableModels + [selected]
    }

    private var modelFreeTextBinding: Binding<String> {
        Binding(
            get: { draft.model ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                draft.model = trimmed.isEmpty ? nil : trimmed
            }
        )
    }

    @MainActor
    private func hydrateLocalModels() async {
        // loadAvailableLocalModels wraps bridge.fetchLocalModels(); empty on failure / offline.
        let models = await loadAvailableLocalModels(bridge: model.bridge)
        availableModels = models
        modelsFetchAttempted = true
    }

    // MARK: - Actions

    private func toggleWeekday(_ day: Int) {
        if let idx = draft.weekdays.firstIndex(of: day) {
            draft.weekdays.remove(at: idx)
        } else {
            draft.weekdays.append(day)
            draft.weekdays.sort()
        }
        if !draft.weekdays.isEmpty {
            validationError = nil
        }
    }

    private func save() {
        draft.time = Self.formatHHMM(timeDate)
        draft.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.frequency == .weekly && draft.weekdays.isEmpty {
            validationError = "Pick at least one day"
            return
        }
        validationError = nil
        if !isNew, let live = model.insightStore.routine(id: draft.id) {
            draft.runState = live.runState
            draft.lastCompletedAt = live.lastCompletedAt
        }
        model.insightStore.upsert(draft)
        model.insightStore.routineErrorMessage = nil
        dismiss()
    }

    private static func formatHHMM(_ date: Date) -> String {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        return String(format: "%02d:%02d", hour, minute)
    }
}
