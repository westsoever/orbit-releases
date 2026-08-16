import SwiftUI

enum PanePosition: String, Sendable {
    case leading
    case center
    case trailing
    case appended
}

struct PaneDescriptor: Identifiable {
    let id: String
    let position: PanePosition
    let preferredWidth: CGFloat
    let isCollapsible: Bool
    let view: AnyView

    init<ID: View>(
        id: String,
        position: PanePosition,
        preferredWidth: CGFloat,
        isCollapsible: Bool = false,
        @ViewBuilder content: () -> ID
    ) {
        self.id = id
        self.position = position
        self.preferredWidth = preferredWidth
        self.isCollapsible = isCollapsible
        self.view = AnyView(content())
    }
}

struct ThreePaneLayout: View {
    let panes: [PaneDescriptor]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(panes) { pane in
                Group {
                    if pane.isCollapsible {
                        pane.view
                    } else {
                        pane.view
                            .frame(minWidth: pane.preferredWidth, idealWidth: pane.preferredWidth)
                    }
                }
                if pane.id != panes.last?.id {
                    OrbitPaneHairline()
                }
            }
        }
    }
}
