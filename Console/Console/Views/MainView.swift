import SwiftUI
import SwiftData

struct MainView: View {
    @State private var themeManager = ThemeManager()
    @AppStorage("sidebarSelection") private var sidebarSelection: SidebarSelection = .home
    @AppStorage("tabSelection") private var tabSelection: TabSelection = .triggers
    @AppStorage(ConsoleNavigation.terminalExpandedKey) private var isTerminalExpanded: Bool = true
    @State private var terminalSessionManager = TerminalSessionManager()
    @State private var terminalPanelHeight: CGFloat = 250
    @State private var terminalResizeStartHeight: CGFloat = 250
    @State private var isResizingTerminal = false
    @State private var didInstallQuitObserver = false
    @Environment(\.modelContext) private var modelContext
    @Environment(PermissionsManager.self) private var permissionsManager
    @Environment(SessionLaunchCoordinator.self) private var launchCoordinator
    @Environment(SessionWorkspaceStore.self) private var workspaceStore
    @Environment(SessionStore.self) private var sessionStore
    @Environment(SessionWorkspaceLayoutController.self) private var sessionWorkspaceLayout

    private static let terminalMinExpandedHeight: CGFloat = 150
    private static let terminalDefaultExpandedHeight: CGFloat = 250
    private static let terminalCenterMinHeight: CGFloat = 200

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selection: $sidebarSelection,
                isTerminalExpanded: drawerExpandedBinding
            )
                .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 240)
        } detail: {
            detailColumn
        }
        .frame(minWidth: 800, maxWidth: .infinity, minHeight: 500, maxHeight: .infinity)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .environment(themeManager)
        .tint(Color.accentColor)
        .preferredColorScheme(themeManager.colorScheme)
        // Shared host for unresolved contextual launches: Jira, GitLab,
        // future Home cards, and the Sessions launcher all land here.
        .sheet(item: collisionSheetBinding) { warning in
            SharedCheckoutWarningSheet(warning: warning)
                .frame(minWidth: 460, maxWidth: 460, minHeight: 280, maxHeight: 480)
        }
        .overlay(alignment: .top) {
            if let failure = launchCoordinator.lastFailure,
               !launchCoordinator.presentsCollisionSheet {
                SessionLaunchErrorBanner(
                    failure: failure,
                    onDismiss: { launchCoordinator.clearFailure() },
                    onOpenSettings: { launchCoordinator.openSessionsSettings() }
                )
                .padding(.top, 8)
            }
        }
        .onChange(of: sidebarSelection) { _, newValue in
            if newValue != .sessions, sessionWorkspaceLayout.isFocusMode {
                sessionWorkspaceLayout.toggleFocusSession()
            }
            if newValue != .settings {
                launchCoordinator.restoreCollisionSheetIfNeeded()
            }
        }
        .onChange(of: isTerminalExpanded) { _, expanded in
            sessionWorkspaceLayout.noteTerminalChrome(
                expanded: expanded,
                height: terminalPanelHeight
            )
        }
        .onChange(of: terminalPanelHeight) { _, height in
            sessionWorkspaceLayout.noteTerminalChrome(
                expanded: isTerminalExpanded,
                height: height
            )
        }
        .onChange(of: sessionWorkspaceLayout.isFocusMode) { _, _ in
            sessionStore.focusSelectedTerminal()
        }
        .onAppear {
            sessionWorkspaceLayout.noteTerminalChrome(
                expanded: isTerminalExpanded,
                height: terminalPanelHeight
            )
            // Conservative migration from the removed bottom-terminal era.
            ConsoleNavigation.migrateLegacyTerminalNavigation()
            // Start the persistent login shell and pre-heat its view off the
            // critical path so the first drawer expansion is instant.
            DispatchQueue.main.async {
                terminalSessionManager.preheatTerminalView()
            }
            installDrawerTerminationOnQuit()
        }
        .onChange(of: tabSelection) { _, newValue in
            // Legacy callers may still set tabSelection; map to sidebar.
            switch newValue {
            case .settings:
                sidebarSelection = .settings
            case .triggers:
                sidebarSelection = .commands
            case .myCommands:
                sidebarSelection = .commands
            case .live:
                // "Live" means the global bottom zsh Terminal drawer,
                // not the Sessions destination.
                withAnimation(TerminalPanelView.collapseAnimation) {
                    isTerminalExpanded = true
                }
            }
        }
    }

    private var collisionSheetBinding: Binding<PendingSharedCheckoutWarning?> {
        Binding(
            get: { launchCoordinator.presentsCollisionSheet ? launchCoordinator.pendingCollision : nil },
            set: { newValue in
                if newValue == nil, launchCoordinator.presentsCollisionSheet {
                    launchCoordinator.cancelSharedCheckoutWarning()
                }
            }
        )
    }

    private var detailColumn: some View {
        ZStack {
            terminalLayout
                .frame(minWidth: 400, maxWidth: .infinity)

            if let permissionType = permissionsManager.pendingPermissionType {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.2)) {
                            permissionsManager.handleDismiss()
                        }
                    }

                PermissionGrantModalView(
                    permissionType: permissionType,
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.2)) {
                            permissionsManager.handleDismiss()
                        }
                    },
                    onGrant: {
                        Task {
                            await permissionsManager.handleGrant()
                        }
                    }
                )
                .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
        }
    }

    /// The global zsh drawer stays expanded only when the user left it that
    /// way and Focus Session is not overlaying a collapsed presentation.
    private var isDrawerVisuallyExpanded: Bool {
        isTerminalExpanded && !sessionWorkspaceLayout.isFocusMode
    }

    private var drawerExpandedBinding: Binding<Bool> {
        Binding(
            get: { isDrawerVisuallyExpanded },
            set: { newValue in
                guard !sessionWorkspaceLayout.isFocusMode else { return }
                isTerminalExpanded = newValue
            }
        )
    }

    private var terminalLayout: some View {
        GeometryReader { geometry in
            let maxTerminalHeight = max(
                Self.terminalMinExpandedHeight,
                geometry.size.height - Self.terminalCenterMinHeight
            )
            let panelHeight = min(
                max(terminalPanelHeight, Self.terminalMinExpandedHeight),
                maxTerminalHeight
            )

            VStack(spacing: 0) {
                centerContent
                    .frame(minWidth: 400, minHeight: Self.terminalCenterMinHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // A retracted drawer occupies no space at all; the shell and
                // its SwiftTerm view survive unmounting inside the manager.
                if isDrawerVisuallyExpanded {
                    terminalResizeHandle(maxHeight: maxTerminalHeight)
                        .transition(.opacity)

                    TerminalPanelView(sessionManager: terminalSessionManager)
                        .frame(height: panelHeight)
                        .frame(maxWidth: .infinity)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(TerminalPanelView.collapseAnimation, value: isDrawerVisuallyExpanded)
            .onAppear {
                terminalPanelHeight = min(
                    max(terminalPanelHeight, Self.terminalDefaultExpandedHeight),
                    maxTerminalHeight
                )
            }
            .onChange(of: geometry.size.height) { _, newHeight in
                let newMax = max(
                    Self.terminalMinExpandedHeight,
                    newHeight - Self.terminalCenterMinHeight
                )
                if terminalPanelHeight > newMax {
                    terminalPanelHeight = newMax
                }
            }
        }
    }

    private func terminalResizeHandle(maxHeight: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if !isResizingTerminal {
                            isResizingTerminal = true
                            terminalResizeStartHeight = terminalPanelHeight
                        }
                        let proposed = terminalResizeStartHeight - value.translation.height
                        terminalPanelHeight = min(
                            max(proposed, Self.terminalMinExpandedHeight),
                            maxHeight
                        )
                    }
                    .onEnded { _ in
                        isResizingTerminal = false
                    }
            )
            .help("Drag to resize Terminal")
    }

    @ViewBuilder
    private var centerContent: some View {
        switch sidebarSelection {
        case .home:
            HomeView()
        case .brief:
            BriefView(workspacesProvider: {
                workspaceStore.availableWorkspaces.map(BriefWorkspaceSnapshot.init)
            })
        case .jira:
            JiraView()
        case .mergeRequests:
            MergeRequestsView()
        case .commands:
            CommandsHubView()
        case .aiProvider:
            AIProviderView()
        case .sessions:
            SessionsView()
        case .settings:
            SettingsView()
        }
    }

    /// Actual termination must also end the app-owned global zsh drawer —
    /// symmetry with the session PTYs that ConsoleApp's quit observer stops.
    /// Hiding or closing the window never reaches this path.
    private func installDrawerTerminationOnQuit() {
        guard !didInstallQuitObserver else { return }
        didInstallQuitObserver = true
        guard !ConsoleApp.isRunningUnitTests else { return }
        let manager = terminalSessionManager
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                manager.stopShellForTermination()
            }
        }
    }
}

#Preview {
    MainView()
        .environment(SessionStore())
        .environment(SessionWorkspaceStore())
        .environment(IOSProjectProfileStore())
        .environment(IOSBuildCoordinator(processRunner: SystemProcessRunner()))
        .environment(SessionLaunchCoordinator(store: SessionStore(), workspaceStore: SessionWorkspaceStore()))
        .environment(SessionWorkspaceLayoutController())
        .modelContainer(for: [Command.self, WakeWord.self], inMemory: true)
}
