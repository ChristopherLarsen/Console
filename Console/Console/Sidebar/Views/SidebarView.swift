import SwiftUI

/// Left sidebar with ConsoleBuddy card and primary navigation.
struct SidebarView: View {
    @Binding var selection: SidebarSelection
    /// Toggle for the global bottom zsh Terminal drawer (MainView owns the
    /// expansion preference and the Focus Mode guard).
    @Binding var isTerminalExpanded: Bool
    @Environment(ThemeManager.self) private var themeManager
    /// The AI Provider destination only exists when enabled in Settings.
    @AppStorage(AppSettings.aiProviderEnabledKey) private var isAIProviderEnabled = false

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
                            label: SidebarSelection.jira.label,
                            icon: SidebarSelection.jira.icon,
                            isSelected: selection == .jira
                        ) {
                            selection = .jira
                        }

                        SidebarRow(
                            label: "GitLab",
                            icon: "arrow.triangle.merge",
                            isSelected: selection == .mergeRequests
                        ) {
                            selection = .mergeRequests
                        }

                        SidebarRow(
                            label: SidebarSelection.sessions.label,
                            icon: SidebarSelection.sessions.icon,
                            isSelected: selection == .sessions
                        ) {
                            selection = .sessions
                        }

                        SidebarRow(
                            label: SidebarSelection.commands.label,
                            icon: SidebarSelection.commands.icon,
                            isSelected: selection == .commands
                        ) {
                            selection = .commands
                        }

                        SidebarRow(
                            label: SidebarSelection.brief.label,
                            icon: SidebarSelection.brief.icon,
                            isSelected: selection == .brief
                        ) {
                            selection = .brief
                        }

                        if isAIProviderEnabled {
                            SidebarRow(
                                label: SidebarSelection.aiProvider.label,
                                icon: SidebarSelection.aiProvider.icon,
                                isSelected: selection == .aiProvider
                            ) {
                                selection = .aiProvider
                            }
                        }
                    }
                }

                Spacer(minLength: 0)

                SidebarSeparator()

                SidebarRow(
                    label: "Terminal",
                    icon: "rectangle.bottomthird.inset.filled",
                    isSelected: false
                ) {
                    withAnimation(TerminalPanelView.collapseAnimation) {
                        isTerminalExpanded.toggle()
                    }
                }
                .help(isTerminalExpanded ? "Retract Terminal" : "Expand Terminal")
                .padding(.horizontal, 8)

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
        .background {
            sidebarHotkeys
        }
    }

    /// Ctrl-1…Ctrl-N select the sidebar destinations in visible order:
    /// the primary list rows, then Settings. AI Provider only claims a
    /// number while the Settings toggle makes its row exist.
    private var sidebarHotkeys: some View {
        ForEach(Array(navigableDestinations.enumerated()), id: \.element) { index, destination in
            Button {
                selection = destination
            } label: {
                EmptyView()
            }
            .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .control)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    private var navigableDestinations: [SidebarSelection] {
        var destinations: [SidebarSelection] = [
            .home, .jira, .mergeRequests, .sessions, .commands, .brief,
        ]
        if isAIProviderEnabled {
            destinations.append(.aiProvider)
        }
        destinations.append(.settings)
        return destinations
    }
}

#Preview {
    @Previewable @State var selection: SidebarSelection = .home
    @Previewable @State var isTerminalExpanded = true
    SidebarView(selection: $selection, isTerminalExpanded: $isTerminalExpanded)
        .environment(ThemeManager())
        .frame(width: 220, height: 500)
}
