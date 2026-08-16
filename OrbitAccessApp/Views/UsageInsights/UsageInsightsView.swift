import SwiftUI

/// Plan 33 Phase 4.1 — the assembled Usage Insights sheet.
///
/// Shell copied from `PrivacyControlsView.swift:18-73`: header + `OrbitHairlineDivider()` +
/// `ScrollView`, `.frame(minWidth:…)`, `.background(Color.orbitCanvas(for:))`,
/// `Button("Done") { dismiss() }` via `OrbitFlatButtonStyle(variant: .secondary)`.
///
/// Three rows, matching the mock at Plan 33 §0.6.2. Every card is a Phase 3 component; this
/// file only supplies the numbers and the two small header rows (App usage / streak) that
/// need a trailing accessory `SectionHeader` does not support.
struct UsageInsightsView: View {
    @Environment(AppViewModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("mainContentMode") private var mainContentMode: MainContentMode = .chat

    /// `pages = totalChars / charsPerWord / wordsPerPage` (Plan 33 Phase 4.1) — named
    /// constants rather than inline magic numbers, so the arithmetic can be checked by
    /// reading the two lines above the call site.
    private static let charsPerWord = 5.5
    private static let wordsPerPage = 500.0

    private var store: UsageInsightsStore { model.usageInsightsStore }
    private var snapshot: UsageSnapshot { store.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            OrbitHairlineDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !model.canBrowseContext {
                        noDatabaseSection
                    } else {
                        row1
                        row2
                        row3
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
        .task {
            await model.usageInsightsStore.load()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Usage insights")
                    .font(.headline)
                Text("How you're using orbit")
                    .font(.caption)
                    .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
            }
            Spacer()
            if store.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Button("Done") { mainContentMode = .chat }
                .buttonStyle(OrbitFlatButtonStyle(variant: .secondary))
        }
        .padding(16)
    }

    // MARK: - No-database state

    /// `!model.canBrowseContext` — no rows, no fabricated zeros. Distinct from the error
    /// caption below: this is "nothing has been captured yet", not "a query failed".
    private var noDatabaseSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No usage data yet")
                .font(.callout.weight(.medium))
            Text("orbit hasn't captured anything on this device yet. Start the daemon and use a " +
                 "few apps, then reopen Insights — this sheet reads only what's already been " +
                 "captured locally, so there's nothing to show until then.")
                .font(.caption)
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .orbitCardChrome(cornerRadius: OrbitShape.radiusSidecard, colorScheme: colorScheme)
    }

    // MARK: - Row 1 — score · capture depth · context captured

    private var row1: some View {
        HStack(alignment: .top, spacing: 16) {
            UsageScoreCard(score: model.insightStore.productivityScore)

            UsageStatTile(
                value: displayNumber(atomsPerActiveHour),
                label: "ATOMS PER HOUR",
                footnote: "\(snapshot.atomsToday.formatted()) atoms in " +
                    "\(snapshot.activeHoursToday) active hour\(snapshot.activeHoursToday == 1 ? "" : "s") today"
            )

            UsageStatTile(
                value: displayNumber(snapshot.totalAtoms),
                label: "ATOMS CAPTURED",
                footnote: "≈ \(pagesOfNotes) pages of notes"
            ) {
                UsageCompositionBar(segments: UsageCompositionBar.captureMethodSegments(snapshot.tiers, colorScheme: colorScheme))
            }
        }
    }

    /// Guarded per the sheet's hard constraint: a fresh install has zeros everywhere, so
    /// every division here goes through `max(1, …)`.
    private var atomsPerActiveHour: Int {
        snapshot.atomsToday / max(1, snapshot.activeHoursToday)
    }

    /// `totalChars / charsPerWord / wordsPerPage`, rounded. For the live §0.4 figure
    /// (1,608,957 chars) this prints 585, matching the mock.
    private var pagesOfNotes: Int {
        Int((Double(snapshot.totalChars) / Self.charsPerWord / Self.wordsPerPage).rounded())
    }

    /// Loading placeholder: values read "—" instead of a stale zero while the first
    /// off-main fetch is still in flight (Plan 33 Phase 4.1 — three required states).
    private func displayNumber(_ value: Int) -> String {
        store.isLoading && store.loadedAt == nil ? "—" : value.formatted()
    }

    // MARK: - Row 2 — app usage · streak

    private var row2: some View {
        HStack(alignment: .top, spacing: 16) {
            appUsageCard
            streakCard
        }
    }

    private var appUsageCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardHeader(title: "App usage", rightLabel: "APPS", rightValue: "\(snapshot.distinctApps)")
            UsageAppBars(apps: snapshot.apps)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .orbitCardChrome(cornerRadius: OrbitShape.radiusSidecard, colorScheme: colorScheme)
    }

    private var streakCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardHeader(
                title: "\(store.currentStreak) day streak",
                rightLabel: "LONGEST",
                rightValue: "\(store.longestStreak)"
            )
            // `UsageStreakGrid` fills its card and no longer states a fixed "last N weeks"
            // window in its own footnote (Plan 41-B: the grid clamps to 26 weeks/182 days,
            // open decision 4, but that's a display width, not a claimed retention window) —
            // nothing to add here.
            UsageStreakGrid(days: snapshot.days, today: store.loadedAt ?? Date())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .orbitCardChrome(cornerRadius: OrbitShape.radiusSidecard, colorScheme: colorScheme)
    }

    /// The `TITLE   RIGHTLABEL | value` header row the mock uses for App usage and streak —
    /// `SectionHeader` itself has no trailing-accessory slot, so this small local helper
    /// supplies just the layout, reusing `SectionHeader`'s type styling by hand.
    private func cardHeader(title: String, rightLabel: String, rightValue: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.callout.weight(.semibold))
            Spacer(minLength: 8)
            Text("\(rightLabel) | \(rightValue)")
                .font(.caption.weight(.semibold))
                .tracking(0.6)
                .monospacedDigit()
                .foregroundStyle(Color.orbitSecondaryText(for: colorScheme))
        }
    }

    // MARK: - Row 3 — tasks · routines · AI usage

    private var row3: some View {
        HStack(alignment: .top, spacing: 16) {
            UsageTallyCard(
                title: "TASKS",
                rows: [
                    UsageTallyCard.Row(label: "detected", value: snapshot.tasks.detected),
                    UsageTallyCard.Row(label: "approved", value: snapshot.tasks.approved),
                    UsageTallyCard.Row(label: "skipped", value: snapshot.tasks.skipped),
                ]
            )

            UsageTallyCard(
                title: "ROUTINES",
                rows: [
                    UsageTallyCard.Row(label: "configured", value: routineTally.total),
                    UsageTallyCard.Row(label: "scheduled today", value: routineTally.scheduledToday),
                    UsageTallyCard.Row(label: "in window now", value: routineTally.inWindowNow),
                    UsageTallyCard.Row(label: "completed today", value: routineTally.completedToday),
                ],
                footnote: UsageTallyCard.routineDisclaimer
            )

            UsageModelCard(
                favourite: store.favouriteModel,
                totalCalls: snapshot.llmCalls,
                okCalls: snapshot.llmOkCalls,
                configuredModel: store.configuredModel
            )
        }
    }

    /// Routines are not loaded by `UsageInsightsStore` (they already live in
    /// `InsightStore.routines`) — read `statusTick`, not `Date()`, exactly as
    /// `RoutineList.swift:8-9` does, so this recomputes on the same 30s poll / sheet-dismiss
    /// tick as the rest of the app rather than drifting on its own clock.
    private var routineTally: RoutineTally {
        RoutineTally.from(
            routines: model.insightStore.routines,
            now: model.insightStore.statusTick,
            calendar: .current
        )
    }
}
