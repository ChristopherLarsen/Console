import SwiftUI

/// Left sidebar with ConsoleBuddy card and primary navigation.
struct SidebarView: View {
    @Binding var selection: SidebarSelection
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
                            label: SidebarSelection.triggers.label,
                            icon: SidebarSelection.triggers.icon,
                            isSelected: selection == .triggers
                        ) {
                            selection = .triggers
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

                        SidebarRow(
                            label: SidebarSelection.jira.label,
                            icon: SidebarSelection.jira.icon,
                            isSelected: selection == .jira
                        ) {
                            selection = .jira
                        }

                        SidebarSeparator()

                        SidebarRow(
                            label: SidebarSelection.terminal.label,
                            icon: SidebarSelection.terminal.icon,
                            isSelected: isTerminalExpanded
                        ) {
                            withAnimation(TerminalPanelView.collapseAnimation) {
                                isTerminalExpanded.toggle()
                            }
                        }
                    }
                }

                Spacer(minLength: 0)

                SidebarSeparator()

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
