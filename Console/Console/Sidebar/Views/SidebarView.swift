import SwiftUI

/// Left sidebar with ConsoleBuddy card and primary navigation.
struct SidebarView: View {
    @Binding var selection: SidebarSelection
    @Environment(ThemeManager.self) private var themeManager
    @AppStorage(AppSettings.codeHostProviderKey) private var codeHostProviderRaw: String = CodeHostProvider.gitlab.rawValue

    /// The code host whose name and icon the merge-requests destination shows.
    private var activeProvider: CodeHostProvider {
        CodeHostProvider(rawValue: codeHostProviderRaw) ?? .gitlab
    }

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
                            label: SidebarSelection.sessions.label,
                            icon: SidebarSelection.sessions.icon,
                            isSelected: selection == .sessions
                        ) {
                            selection = .sessions
                        }

                        SidebarRow(
                            label: activeProvider.displayName,
                            icon: activeProvider.sidebarIcon,
                            isSelected: selection == .mergeRequests
                        ) {
                            selection = .mergeRequests
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
    SidebarView(selection: $selection)
        .environment(ThemeManager())
        .frame(width: 220, height: 500)
}
