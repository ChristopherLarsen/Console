import SwiftUI

/// The four Home dashboard quadrants in fixed reading order.
enum HomePanel: Int, CaseIterable, Identifiable {
    case jiraTickets
    case sessions
    case gitLabReviews
    case gitLabAuthored

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .jiraTickets: return "My Tickets"
        case .sessions: return "Sessions"
        case .gitLabReviews: return "MRs to Review"
        case .gitLabAuthored: return "My MRs"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .jiraTickets: return "HomePanelJiraTickets"
        case .sessions: return "HomePanelSessions"
        case .gitLabReviews: return "HomePanelGitLabMRsToReview"
        case .gitLabAuthored: return "HomePanelGitLabMyMRs"
        }
    }
}

/// Four-panel Home dashboard frame: JIRA tickets, sessions, and both hosted
/// merge-request lists for whichever code host Console currently targets.
struct HomeView: View {
    private enum Layout {
        static let edgePadding: CGFloat = 12
        static let gridSpacing: CGFloat = 12
        static let minimumPanelWidth: CGFloat = 160
        static let minimumPanelHeight: CGFloat = 160
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(AppSettings.codeHostProviderKey) private var codeHostProviderRaw: String = CodeHostProvider.gitlab.rawValue

    /// The code host whose panels Home renders right now. Switching hosts in
    /// Settings re-renders these quadrants immediately.
    private var activeProvider: CodeHostProvider {
        CodeHostProvider(rawValue: codeHostProviderRaw) ?? .gitlab
    }

    /// Accessibility text sizes need taller rows so placeholder text never clips.
    private var minimumPanelHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize
            ? Layout.minimumPanelHeight * 1.6
            : Layout.minimumPanelHeight
    }

    var body: some View {
        GeometryReader { geometry in
            // Equal rows that fill the available height, clamped to a minimum so
            // both rows survive short windows by scrolling instead of collapsing.
            let rowHeight = max(
                minimumPanelHeight,
                (geometry.size.height - 2 * Layout.edgePadding - Layout.gridSpacing) / 2
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
                    GridRow {
                        panel(.gitLabReviews)
                            .frame(height: rowHeight)
                        panel(.gitLabAuthored)
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
        case .gitLabReviews, .gitLabAuthored: return activeProvider.displayName
        }
    }

    private func panel(_ panel: HomePanel) -> some View {
        HomePanelContainer(
            title: panel.title,
            subtitle: serviceLabel(for: panel),
            // JIRA and Sessions own custom headers with actions; the container
            // supplies only the card chrome and accessibility identifier.
            showsHeader: panel != .jiraTickets && panel != .sessions,
            accessibilityIdentifier: panel.accessibilityIdentifier
        ) {
            switch panel {
            case .jiraTickets:
                JiraPanelView()
            case .sessions:
                HomeSessionsPanelView()
            case .gitLabReviews:
                MergeRequestsPanelView(provider: activeProvider, kind: .reviewsRequested)
            case .gitLabAuthored:
                MergeRequestsPanelView(provider: activeProvider, kind: .authored)
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
