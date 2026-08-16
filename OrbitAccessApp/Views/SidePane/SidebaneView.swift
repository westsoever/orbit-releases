import SwiftUI

struct SidebaneView: View {
    @Environment(AppViewModel.self) private var model
    @AppStorage("agentsExpanded") private var agentsExpanded = false

    private let railAgents: [AgentType] = [.writing, .research, .code, .admin]

    var body: some View {
        VStack(alignment: .leading, spacing: .zero) {
            ScrollView {
                VStack(alignment: .leading, spacing: SidebaneMetrics.groupSpacing) {
                    VStack(alignment: .leading, spacing: SidebaneMetrics.rowSpacing) {
                        NewChatButton()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ChatHistoryDropdownMenu()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        TasksTabRow()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        TimelineTabRow()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    VStack(alignment: .leading, spacing: SidebaneMetrics.rowSpacing) {
                        AgentsFoldRow(isExpanded: $agentsExpanded)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if agentsExpanded {
                            VStack(alignment: .leading, spacing: SidebaneMetrics.rowSpacing) {
                                ForEach(railAgents, id: \.self) { agent in
                                    AgentShortcutRow(agentType: agent)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(.leading, 10)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.hidden)
            .frame(minHeight: 0)

            VStack(alignment: .leading, spacing: SidebaneMetrics.groupSpacing) {
                VStack(alignment: .leading, spacing: SidebaneMetrics.rowSpacing) {
                    SidebaneCaptureFooter()
                    SidebanePrivacyRow()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    SidebaneUsageInsightsRow()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                OrbitHairlineDivider(horizontalPadding: 0)

                DaemonStatusIndicator()
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .sheet(isPresented: Bindable(model).showPrivacyControls) {
            PrivacyControlsView()
        }
    }
}
