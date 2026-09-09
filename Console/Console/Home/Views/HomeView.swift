import SwiftUI

/// The Home dashboard panels in fixed reading order.
enum HomePanel: Int, CaseIterable, Identifiable {
    case jiraTickets
    case sessions

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .jiraTickets: return "My Tickets"
        case .sessions: return "Sessions"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .jiraTickets: return "HomePanelJiraTickets"
        case .sessions: return "HomePanelSessions"
        }
    }
}

/// Two-panel Home dashboard frame: JIRA tickets and sessions.
struct HomeView: View {
    private enum Layout {
        static let edgePadding: CGFloat = 12
        static let gridSpacing: CGFloat = 12
        static let minimumPanelWidth: CGFloat = 160
        static let minimumPanelHeight: CGFloat = 160
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Accessibility text sizes need taller rows so placeholder text never clips.
    private var minimumPanelHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize
            ? Layout.minimumPanelHeight * 1.6
            : Layout.minimumPanelHeight
    }

    var body: some View {
        GeometryReader { geometry in
            // Single row that fills the available height, clamped to a minimum
            // so the panels survive short windows by scrolling instead of
            // collapsing.
            let rowHeight = max(
                minimumPanelHeight,
                geometry.size.height - 2 * Layout.edgePadding
            )

            ScrollView(.vertical) {
                Grid(
                    alignment: .center,
                    horizontalSpacing: Layout.gridSpacing,
                    verticalSpacing: Layout.gridSpacing
                ) {
                    GridRow {
                        panel(.jiraTickets)
                            .frame(height: rowHeight)
                        panel(.sessions)
                            .frame(height: rowHeight)
                    }
                }
                .padding(Layout.edgePadding)
                .frame(minWidth: geometry.size.width)
            }
        }
        .accessibilityIdentifier("HomeDashboard")
    }

    private func serviceLabel(for panel: HomePanel) -> String? {
        switch panel {
        case .jiraTickets: return "JIRA"
        case .sessions: return nil
        }
    }

    private func panel(_ panel: HomePanel) -> some View {
        HomePanelContainer(
            title: panel.title,
            subtitle: serviceLabel(for: panel),
            // Every panel renders exactly one header of its own; the
            // container supplies only the card chrome and accessibility
            // identifier.
            accessibilityIdentifier: panel.accessibilityIdentifier
        ) {
            switch panel {
            case .jiraTickets:
                JiraPanelView()
            case .sessions:
                HomeSessionsPanelView()
            }
        }
        .frame(
            minWidth: Layout.minimumPanelWidth,
            maxWidth: .infinity
        )
    }
}

#Preview("Home Dashboard") {
    HomeView()
        .frame(width: 900, height: 560)
}
