import AppKit
import SwiftUI

struct PrivacyControlsView: View {
    @Environment(AppViewModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var newBundle = ""
    @State private var confirmDelete = false
    @State private var forgetMinutes = 15

    private var store: PrivacyStore { model.privacyStore }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            OrbitHairlineDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    setupChecklistSection
                    captureHealthSection
                    pauseSection
                    exclusionsSection
                    forgetSection
                    exportDeleteSection
                    policyLink
                    if let status = store.statusMessage {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                    }
                    if let error = store.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Color.orbitScoreRed)
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 420, idealWidth: 460, minHeight: 520, idealHeight: 640)
        .background(Color.orbitCanvas(for: colorScheme))
        .task {
            await store.refresh()
            model.isCapturePaused = store.capturePaused
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Privacy & setup")
                    .font(.headline)
                Text("Pause, exclude, forget, and verify capture")
                    .font(.caption)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
            }
            Spacer()
            if store.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Button("Done") { dismiss() }
                .buttonStyle(OrbitFlatButtonStyle(variant: .secondary))
        }
        .padding(16)
    }

    private var setupChecklistSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "SETUP")
            OrbitCard {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(store.setupChecklist) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Circle()
                                .fill(item.ok ? Color.orbitScoreEmerald : Color.orbitScoreRed)
                                .frame(width: 8, height: 8)
                                .padding(.top, 4)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.label)
                                    .font(.callout.weight(.medium))
                                if let detail = item.detail, !detail.isEmpty {
                                    Text(detail)
                                        .font(.caption2)
                                        .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                                }
                            }
                            Spacer(minLength: 4)
                            if item.id == "accessibility", !item.ok {
                                // Do NOT call AccessibilityPermissions.promptIfNeeded() here: that
                                // AX trust prompt is about *this app*, not the daemon process that
                                // actually needs the grant, so it never resolves the red row and
                                // makes the button feel broken. The daemon's own `detail` string
                                // above already names the process to grant (e.g. "Grant
                                // Accessibility to Terminal/Python…") — just get System Settings
                                // open and let the user act on that copy.
                                Button("Open Settings") {
                                    _ = AccessibilityPermissions.openSystemSettings()
                                }
                                .buttonStyle(OrbitFlatButtonStyle(variant: .ghost))
                            }
                            if item.id == "daemon", !item.ok {
                                Button("Start") {
                                    Task { await model.startDaemon() }
                                }
                                .buttonStyle(OrbitFlatButtonStyle(variant: .primary))
                            }
                            if item.id == "llm", !item.ok {
                                Button("Cloud AI…") {
                                    dismiss()
                                    model.showCloudAISettings = true
                                }
                                .buttonStyle(OrbitFlatButtonStyle(variant: .ghost))
                            }
                        }
                    }
                }
            }
        }
    }

    private var captureHealthSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "CAPTURE HEALTH (24H)")
            if store.captureHealthApps.isEmpty {
                Text(model.isDaemonOnline
                      ? "No recent captures yet — use a few apps with the daemon running."
                      : "Start the daemon to load capture health.")
                    .font(.caption)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.captureHealthApps.prefix(12)) { app in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(healthColor(app.status))
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.appName)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                Text(app.bundleId)
                                    .font(.caption2)
                                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Text(healthLabel(app))
                                .font(.caption2)
                                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                            if !app.excluded, app.status == "empty" || app.status == "partial" {
                                Button("Exclude") {
                                    Task { await store.addExclusion(app.bundleId) }
                                }
                                .buttonStyle(OrbitFlatButtonStyle(variant: .ghost))
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private var pauseSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "CAPTURE")
            OrbitCard {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.capturePaused ? "Capture paused" : "Capture active")
                            .font(.callout.weight(.medium))
                        Text("Stops new AX captures without quitting the daemon")
                            .font(.caption2)
                            .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                    }
                    Spacer()
                    Button(store.capturePaused ? "Resume" : "Pause") {
                        Task {
                            await store.togglePause()
                            model.isCapturePaused = store.capturePaused
                        }
                    }
                    .buttonStyle(OrbitFlatButtonStyle(variant: store.capturePaused ? .primary : .secondary))
                    .disabled(!model.isDaemonOnline)
                }
            }
        }
    }

    private var exclusionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "EXCLUDED APPS")
            HStack(spacing: 8) {
                TextField("Bundle ID (e.g. com.apple.Safari)", text: $newBundle)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                Button("Add") {
                    let value = newBundle
                    newBundle = ""
                    Task { await store.addExclusion(value) }
                }
                .buttonStyle(OrbitFlatButtonStyle(variant: .ghost))
                .disabled(newBundle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.isDaemonOnline)
            }
            if store.excludedBundles.isEmpty {
                Text("No user exclusions. Built-in privacy apps stay blocked.")
                    .font(.caption2)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
            } else {
                ForEach(store.excludedBundles, id: \.self) { bundle in
                    HStack {
                        Text(bundle)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Button("Remove") {
                            Task { await store.removeExclusion(bundle) }
                        }
                        .buttonStyle(OrbitFlatButtonStyle(variant: .ghost))
                        .disabled(!model.isDaemonOnline)
                    }
                }
            }
            if !store.builtinExclusions.isEmpty {
                Text("Built-in: \(store.builtinExclusions.prefix(4).joined(separator: ", "))…")
                    .font(.caption2)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
            }
        }
    }

    private var forgetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "FORGET RECENT")
            HStack(spacing: 8) {
                Picker("Minutes", selection: $forgetMinutes) {
                    Text("15 min").tag(15)
                    Text("60 min").tag(60)
                    Text("3 hours").tag(180)
                }
                .labelsHidden()
                .frame(maxWidth: 140)
                Button("Forget") {
                    Task { await store.forget(minutes: forgetMinutes) }
                }
                .buttonStyle(OrbitFlatButtonStyle(variant: .ghost))
                .disabled(!model.isDaemonOnline)
            }
            Text("Deletes capture events from the last N minutes.")
                .font(.caption2)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
        }
    }

    private var exportDeleteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "YOUR DATA")
            HStack(spacing: 8) {
                Button("Export…") {
                    Task { await store.exportData() }
                }
                .buttonStyle(OrbitFlatButtonStyle(variant: .secondary))
                .disabled(!model.isDaemonOnline)
                Button("Delete all…") {
                    confirmDelete = true
                }
                .buttonStyle(OrbitFlatButtonStyle(variant: .destructive))
                .disabled(!model.isDaemonOnline)
            }
            Text("Export writes JSONL under ~/.orbit/exports/")
                .font(.caption2)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
        }
        .confirmationDialog(
            "Delete all capture data?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete everything", role: .destructive) {
                Task { await store.deleteAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes all context events and text atoms from the local database.")
        }
    }

    private var policyLink: some View {
        Button("Open privacy policy") {
            if let url = OrbitPaths.privacyPolicyURL() {
                NSWorkspace.shared.open(url)
            }
        }
        .font(.caption)
        .buttonStyle(.link)
    }

    private func healthColor(_ status: String) -> Color {
        switch status {
        case "good": return .orbitScoreEmerald
        case "partial": return .orbitScoreAmber
        case "blocked": return .orbitSecondaryText(for: colorScheme)
        default: return .orbitScoreRed
        }
    }

    private func healthLabel(_ app: CaptureHealthApp) -> String {
        switch app.status {
        case "good": return "Good · \(app.goodCount)"
        case "partial": return "Partial · \(app.goodCount)/\(app.eventCount)"
        case "empty": return "Empty"
        case "blocked": return "Excluded"
        default: return app.status
        }
    }
}
