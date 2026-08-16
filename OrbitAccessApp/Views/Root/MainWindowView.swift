import SwiftUI

struct MainWindowView: View {
    @Environment(AppViewModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("sidebaneVisible") private var sidebaneVisible = true
    @AppStorage("insightVisible") private var insightVisible = true
    @AppStorage("chatIsFloating") private var chatIsFloating = false
    @AppStorage("mainContentMode") private var mainContentMode: MainContentMode = .chat
    /// Plan 53 Phase 2. Raw-string key repeated at each site (also read/written by
    /// `TourView` and `OrbitSettingsView`), matching the convention in `OrbitAccessApp.swift`.
    @AppStorage("hasCompletedTour") private var hasCompletedTour = false

    /// The Sidecard (right) overlay is force-hidden whenever the center pane isn't chat —
    /// Tasks, Timeline, and Insights (Plan 44 item 6) all hide it — `insightVisible` itself is
    /// never written here, so switching back to chat restores whatever visibility it had
    /// before.
    private var isSidecardVisible: Bool {
        insightVisible && mainContentMode == .chat
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ThreePaneLayout(panes: [
                PaneDescriptor(id: "chat", position: .center, preferredWidth: 480) {
                    Group {
                        switch mainContentMode {
                        case .chat:
                            if chatIsFloating {
                                FloatingChatPlaceholderView()
                            } else {
                                MainChatView()
                            }
                        case .tasks:
                            KanbanBoardView()
                        case .timeline:
                            TimelineView()
                        case .insights:
                            UsageInsightsView()
                                .padding(.leading, sidebaneVisible ? SidebaneMetrics.gutter : 0)
                                .animation(OrbitMotion.collapse, value: sidebaneVisible)
                        }
                    }
                },
            ])
            .frame(minWidth: 900, minHeight: 600)

            SidebaneOverlay()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, SidebaneMetrics.leadingMargin)
                .padding(.top, SidebaneMetrics.topMargin)
                .padding(.bottom, SidebaneMetrics.bottomMargin)
                .opacity(sidebaneVisible ? 1 : 0)
                .allowsHitTesting(sidebaneVisible)
                .animation(OrbitMotion.collapse, value: sidebaneVisible)

            SidecardOverlay()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.trailing, SidecardMetrics.trailingMargin)
                .padding(.top, SidecardMetrics.topMargin)
                .opacity(isSidecardVisible ? 1 : 0)
                .allowsHitTesting(isSidecardVisible)
                .animation(OrbitMotion.collapse, value: isSidecardVisible)

            // Fixed-position reveal/hide controls for both panes. These live as ZStack
            // siblings — NOT inside SidebaneOverlay/SidecardOverlay — specifically so they
            // do NOT opacity-fade with their pane: they are the only way back once a pane
            // is hidden (previously the right pane's only hide control lived inside
            // SidecardHeader and vanished along with the pane itself; the left pane had no
            // button at all, only ⌘S). Corner margins match the overlay each button anchors
            // to, so the button sits exactly where that pane's own corner sits regardless of
            // the pane's current visibility.
            OrbitIconButton(
                label: sidebaneVisible ? "Hide left sidebar" : "Show left sidebar",
                systemImage: sidebaneVisible ? "chevron.left" : "chevron.right"
            ) {
                sidebaneVisible.toggle()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // Rides with the pane instead of sitting at a fixed corner. Open, it parks in the
            // trailing slot `SidebaneShell.header` already reserves with a `Spacer` — anchoring
            // it at `leadingMargin` instead put it on top of the "orbit" wordmark. Collapsed,
            // it returns to the window edge, which is the only way back once the pane is hidden.
            .padding(.leading, sidebaneVisible ? SidebaneMetrics.toggleLeadingOpen : SidebaneMetrics.leadingMargin)
            .padding(.top, SidebaneMetrics.topMargin + (sidebaneVisible ? SidebaneMetrics.toggleTopInset : 0))
            .animation(OrbitMotion.collapse, value: sidebaneVisible)

            // Gated on `isSidecardVisible` (mode-aware), not raw `insightVisible`, and hidden
            // entirely off `.chat` — the Sidecard is force-hidden by mode there, not by
            // `insightVisible`, so revealing this button would let the user flip
            // `insightVisible` on with zero visible effect until they return to chat. The tap
            // action still only ever writes `insightVisible` (there's no other backing store).
            if mainContentMode == .chat {
                OrbitIconButton(
                    label: isSidecardVisible ? "Hide widgets" : "Show widgets",
                    systemImage: isSidecardVisible ? "chevron.right" : "chevron.left"
                ) {
                    insightVisible.toggle()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.trailing, SidecardMetrics.trailingMargin)
                .padding(.top, SidecardMetrics.topMargin)
                .animation(OrbitMotion.collapse, value: isSidecardVisible)
            }

            // Drawn LAST, on purpose. It used to sit before `SidebaneOverlay` in this ZStack
            // while anchored bottom-leading — exactly where the sidebar lives — so the sidebar
            // painted over it and the card appeared as a fragment sticking out from behind the
            // pane. Being last puts it above both overlays, and the leading pad clears the
            // sidebar's gutter when the pane is open so the two never occupy the same space.
            if let issue = model.seriousIssue {
                OrbitIssueNotificationHost(issue: issue) {
                    Task { await model.retryDaemonConnection() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, sidebaneVisible ? SidebaneMetrics.gutter : 16)
                .padding(.bottom, 16)
                .animation(OrbitMotion.collapse, value: sidebaneVisible)
            }
        }
        .orbitCanvasBackground(colorScheme: colorScheme)
        // Attached to the outer ZStack (not the insightVisible-gated SidecardOverlay)
        // so routine creation/editing can present regardless of sidecard visibility.
        .sheet(item: Bindable(model).editingRoutine, onDismiss: {
            model.dismissRoutineEditor()
        }) { routine in
            EditRoutineView(routine: routine, isNew: model.editingRoutineIsNew)
        }
        // Plan 53 Phase 2 — the onboarding tour. Same `Bindable(model)` sheet idiom as the
        // routine editor above. NOT gated on `isSignedIn`: after Phase 1 the common case is a
        // local-only identity, and that user needs the tour more than a signed-in one does.
        .sheet(isPresented: Bindable(model).showTour) {
            TourView()
        }
        // Plan 53 Phase 4 — the optional cloud sign-in. Same sheet idiom again. Nothing sets
        // `showSignIn` on launch: it is raised from Settings, or once after the tour is
        // completed, and only when `canOfferCloudSignIn` is true. Dismissing it costs the
        // user nothing (decision D2).
        .sheet(isPresented: Bindable(model).showSignIn) {
            OnboardingContainerView()
        }
        // Plan 53 Phase 6 — the optional profile questionnaire. Only ever raised *after* a
        // successful sign-in (or from Settings › Account), never on launch and never for a
        // local-only Mac: the answers sync to the relay and have nowhere else to go.
        .sheet(isPresented: Bindable(model).showProfileQuestions) {
            ProfileQuestionsView()
        }
        .task {
            if !hasCompletedTour {
                model.showTour = true
            }
        }
    }
}
