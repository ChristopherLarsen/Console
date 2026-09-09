import SwiftUI

/// Left sidebar with ConsoleBuddy card and primary navigation.
struct SidebarView: View {
    @Binding var selection: SidebarSelection
    /// Toggle for the global bottom zsh Terminal drawer (MainView owns the
    /// expansion preference and the Focus Mode guard).
    @Binding var isTerminalExpanded: Bool
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: "FFFFFF"), Color(hex: "F4F4F4")],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                ConnectedBuddyView()
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 8)

                CustomSidebarList {
                    SidebarSection(header: nil) {
                        SidebarRow(
                            label: SidebarSelection.home.label,
                            icon: SidebarSelection.home.icon,
                            isSelected: selection == .home
                        ) {
                            selection = .home
                        }

                        SidebarRow(
                            label: SidebarSelection.next.label,
                            icon: SidebarSelection.next.icon,
                            isSelected: selection == .next
                        ) {
                            selection = .next
                        }

                        SidebarRow(
                            label: SidebarSelection.brief.label,
                            icon: SidebarSelection.brief.icon,
                            isSelected: selection == .brief
                        ) {
                            selection = .brief
                        }

                        SidebarRow(
                            label: SidebarSelection.jira.label,
                            icon: SidebarSelection.jira.icon,
                            isSelected: selection == .jira
                        ) {
                            selection = .jira
                        }

                        SidebarRow(
                            label: SidebarSelection.ticketWork.label,
                            icon: SidebarSelection.ticketWork.icon,
                            isSelected: selection == .ticketWork
                        ) {
                            selection = .ticketWork
                        }
                        .accessibilityIdentifier(TicketWorkflowAccessibility.sidebarItem)

                        SidebarRow(
                            label: SidebarSelection.sessions.label,
                            icon: SidebarSelection.sessions.icon,
                            isSelected: selection == .sessions
                        ) {
                            selection = .sessions
                        }

                        SidebarRow(
                            label: "GitLab",
                            icon: "arrow.triangle.merge",
                            isSelected: selection == .mergeRequests
                        ) {
                            selection = .mergeRequests
                        }

                        SidebarRow(
                            label: SidebarSelection.commands.label,
                            icon: SidebarSelection.commands.icon,
                            isSelected: selection == .commands
                        ) {
                            selection = .commands
                        }

                        SidebarRow(
                            label: SidebarSelection.aiProvider.label,
                            icon: SidebarSelection.aiProvider.icon,
                            isSelected: selection == .aiProvider
                        ) {
                            selection = .aiProvider
                        }
                    }
                }

                Spacer(minLength: 0)

                SidebarSeparator()

                SidebarRow(
                    label: "Main Terminal",
                    icon: "rectangle.bottomthird.inset.filled",
                    isSelected: false
                ) {
                    withAnimation(TerminalPanelView.collapseAnimation) {
                        isTerminalExpanded.toggle()
                    }
                }
                .help(isTerminalExpanded ? "Retract Terminal" : "Expand Terminal")

                SidebarRow(
                    label: SidebarSelection.settings.label,
                    icon: SidebarSelection.settings.icon,
                    isSelected: selection == .settings
                ) {
                    selection = .settings
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    @Previewable @State var selection: SidebarSelection = .home
    @Previewable @State var isTerminalExpanded = true
    SidebarView(selection: $selection, isTerminalExpanded: $isTerminalExpanded)
        .environment(ThemeManager())
        .frame(width: 220, height: 500)
}
