import SwiftUI
import SwiftData
import AppKit
import ServiceManagement

// Minimizes to the Dock on window close instead of destroying the window
private struct WindowCloseInterceptor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            context.coordinator.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSWindowDelegate {
        private weak var originalDelegate: NSWindowDelegate?

        func attach(to window: NSWindow) {
            originalDelegate = window.delegate
            window.delegate = self
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            sender.miniaturize(nil)
            return false
        }

        override func responds(to aSelector: Selector!) -> Bool {
            if super.responds(to: aSelector) { return true }
            return originalDelegate?.responds(to: aSelector) ?? false
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if let orig = originalDelegate, orig.responds(to: aSelector) { return orig }
            return super.forwardingTarget(for: aSelector)
        }
    }
}

@main
struct ConsoleApp: App {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase

    @State private var menuBarViewModel: MenuBarViewModel
    @State private var infoManager = InfoManager()
    @State private var modelContainerError: String?
    @State private var modelContainer: ModelContainer

    @State private var permissionObserver = PermissionBackgroundObserver()
    @State private var permissionsManager = PermissionsManager()
    @State private var servicesManager = ServicesManager()

    @State private var aiProviderManager = AIProviderManager()
    @State private var localCommandExecutor = LocalCommandExecutor()
    @State private var wakeWordManager: WakeWordManager?
    @State private var updateManager: UpdateManager
    @State private var sessionStore: SessionStore
    @State private var nextButtonModel: NextButtonModel
    @State private var workspaceStore: SessionWorkspaceStore
    @State private var iosProfileStore: IOSProjectProfileStore
    @State private var iosBuildCoordinator: IOSBuildCoordinator
    @State private var launchCoordinator: SessionLaunchCoordinator
    @State private var sessionWorkspaceLayout = SessionWorkspaceLayoutController()
    @State private var developerActions: DeveloperActionRunner
    @State private var ticketWorkflowStore: TicketWorkflowStore
    @State private var ticketWorkflowCoordinator: TicketWorkflowCoordinator
    private var syntheticTranscriptSource: SyntheticTranscriptSource?
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false
    @AppStorage("tabSelection") private var tabSelection: TabSelection = .triggers
    #if DEBUG
    @State private var developerModeManager = DeveloperModeManager()
    @AppStorage("alwaysOnTop") private var alwaysOnTop: Bool = false
    #endif

    @State private var didRunAppBootstrap = false

    // Detect if running in unit test environment
    private static var isRunningUnitTests: Bool {
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    init() {
        UserDefaults.standard.register(defaults: [
            "enableBuiltInCommands": true,
            "recognizeBuiltInCommands": true,
            "showCommandPopups": false,
            "showErrorPopups": false,
            "popupDurationSeconds": 3,
            "listenOnStartup": true
        ])

        let workspaceStore = SessionWorkspaceStore()
        _workspaceStore = State(initialValue: workspaceStore)
        let iosProfileStore = IOSProjectProfileStore()
        let iosBuildCoordinator = IOSBuildCoordinator(processRunner: SystemProcessRunner())
        _iosProfileStore = State(initialValue: iosProfileStore)
        _iosBuildCoordinator = State(initialValue: iosBuildCoordinator)

        // Always open on Home for each process launch (do not restore last sidebar page).
        UserDefaults.standard.set(SidebarSelection.home.rawValue, forKey: ConsoleNavigation.sidebarKey)
        // Conservative migration from the removed bottom-terminal era.
        ConsoleNavigation.migrateLegacyTerminalNavigation()

        NSWindow.allowsAutomaticWindowTabbing = false

        // Parse launch arguments for test automation
        let args = ProcessInfo.processInfo.arguments

        if let synthIdx = args.firstIndex(of: "--synthetic-speech"),
           synthIdx + 1 < args.count,
           let data = args[synthIdx + 1].data(using: .utf8),
           let entries = try? JSONDecoder().decode([TranscriptEntry].self, from: data) {
            syntheticTranscriptSource = SyntheticTranscriptSource(entries: entries)
        }

        let schema = Schema([
            Command.self,
            WakeWord.self,
        ])

        #if DEBUG
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let storeDir = appSupport.appending(path: "Console")
        try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let storeURL = storeDir.appending(path: "ConsoleDev.store")

        // One-time migration: copy old default.store into the stable location
        if !FileManager.default.fileExists(atPath: storeURL.path(percentEncoded: false)) {
            let oldStore = appSupport.appending(path: "default.store")
            if FileManager.default.fileExists(atPath: oldStore.path(percentEncoded: false)) {
                try? FileManager.default.copyItem(at: oldStore, to: storeURL)
                for ext in ["-shm", "-wal"] {
                    let src = appSupport.appending(path: "default.store\(ext)")
                    let dst = storeDir.appending(path: "ConsoleDev.store\(ext)")
                    try? FileManager.default.copyItem(at: src, to: dst)
                }
                printDebug("[Console] Migrated default.store → ConsoleDev.store")
            }
        }

        let modelConfiguration = ModelConfiguration(schema: schema, url: storeURL)
        #else
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        #endif

        let storeLocationKey = "swiftDataStoreLocation"
        let currentPath = modelConfiguration.url.path(percentEncoded: false)
        let storeExists = FileManager.default.fileExists(atPath: currentPath)
        printDebug("[Console] Store URL: \(currentPath), exists: \(storeExists)")
        if let savedPath = UserDefaults.standard.string(forKey: storeLocationKey) {
            if savedPath != currentPath {
                printDebug("[Console] ⚠️ SwiftData store location changed!\n  Previous: \(savedPath)\n  Current:  \(currentPath)")
            }
        }
        UserDefaults.standard.set(currentPath, forKey: storeLocationKey)

        var container: ModelContainer?
        var openMode = ""

        do {
            container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            openMode = "persistent"
        } catch {
            printDebug("[Console] Persistent store open failed (first attempt): \(error)")
            do {
                container = try ModelContainer(for: schema, configurations: [modelConfiguration])
                openMode = "persistent_retry"
            } catch {
                printDebug("[Console] Persistent store open failed (retry): \(error). Using in-memory fallback — store files preserved.")
                let inMemoryConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                container = try! ModelContainer(for: schema, configurations: [inMemoryConfig])
                openMode = "in_memory"
            }
        }

        let finalContainer = container!
        _modelContainer = State(initialValue: finalContainer)
        let ctx = finalContainer.mainContext
        let commandCount = (try? ctx.fetchCount(FetchDescriptor<Command>())) ?? 0
        let wakeWordCount = (try? ctx.fetchCount(FetchDescriptor<WakeWord>())) ?? 0
        printDebug("[Console] SwiftData \(openMode) opened. Commands: \(commandCount), WakeWords: \(wakeWordCount)")
        if openMode == "in_memory" {
            _modelContainerError = State(initialValue: "Could not open persistent store. Data will not persist this session.")
        } else {
            _modelContainerError = State(initialValue: nil)
        }
        AppDependencies.shared.modelContainer = finalContainer

        let vm = MenuBarViewModel()
        _menuBarViewModel = State(initialValue: vm)
        MenuBarViewModel.shared = vm

        let updates = UpdateManager()
        _updateManager = State(initialValue: updates)

        let sessionStore = SessionStore()
        _sessionStore = State(initialValue: sessionStore)
        let nextButtonModel = NextButtonModel()
        _nextButtonModel = State(initialValue: nextButtonModel)
        let coordinator = SessionLaunchCoordinator(store: sessionStore, workspaceStore: workspaceStore)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiTestSessionLaunchFailure") {
            coordinator.debugPresentSyntheticFailure()
        }
        #endif
        _launchCoordinator = State(initialValue: coordinator)
        _developerActions = State(initialValue: DeveloperActionRunner())

        let ticketStore = TicketWorkflowStore(
            identityKeyManager: TicketIdentityKeyProvider(),
            fileStore: TicketWorkflowFileStore()
        )
        let ticketCoordinator = TicketWorkflowCoordinator(store: ticketStore)
        ticketCoordinator.buildCoordinator = iosBuildCoordinator
        ticketCoordinator.profileStore = iosProfileStore
        ticketCoordinator.workspaceStore = workspaceStore
        _ticketWorkflowStore = State(initialValue: ticketStore)
        _ticketWorkflowCoordinator = State(initialValue: ticketCoordinator)
        _ = sessionStore.addLifecycleSubscriber { sessionID, event in
            ticketCoordinator.handleSessionLifecycle(sessionID: sessionID, event: event)
        }

        if !Self.isRunningUnitTests {
            MenuBarManager.shared.installStatusItem()

            let activeSessionStore = sessionStore
            let activeNextModel = nextButtonModel
            // Cancel any in-flight update check or clone when the app terminates.
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak updates] _ in
                MainActor.assumeIsolated {
                    updates?.cancelAll()
                    activeNextModel.cancel()
                    // Real termination stops all session processes; hiding the
                    // window never reaches this path.
                    activeSessionStore.terminateAll()
                    activeSessionStore.stopBridge()
                }
            }
        }

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiTestSelectSessions")
            || ProcessInfo.processInfo.arguments.contains("-uiTestSessionsPreview") {
            UserDefaults.standard.set(SidebarSelection.sessions.rawValue, forKey: ConsoleNavigation.sidebarKey)
        }
        if ProcessInfo.processInfo.arguments.contains("-uiTestSelectGitLab") {
            UserDefaults.standard.set(SidebarSelection.mergeRequests.rawValue, forKey: ConsoleNavigation.sidebarKey)
        }
        if ProcessInfo.processInfo.arguments.contains("-uiTestSelectNext") {
            UserDefaults.standard.set(SidebarSelection.next.rawValue, forKey: ConsoleNavigation.sidebarKey)
        }
        if ProcessInfo.processInfo.arguments.contains("-uiTestNextSyntheticSources") {
            nextButtonModel.installSyntheticUITestSources()
        }
        if ProcessInfo.processInfo.arguments.contains("-uiTestSessionsPreview") {
            sessionStore.injectUITestPreviewSessions()
        }
        // Home radar preview: injected sessions while staying on Home — this
        // flag deliberately does not touch sidebarSelection.
        if ProcessInfo.processInfo.arguments.contains("-uiTestHomeSessionsPreview") {
            sessionStore.injectUITestPreviewSessions()
        }
        #endif
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            Group {
            // Don't show UI during unit tests to prevent window activation
            if Self.isRunningUnitTests {
                Text("Running Unit Tests...")
                    .frame(width: 0, height: 0)
                    .hidden()
            } else {
                ZStack {
                    Group {
                        MainView()
                            .background(WindowCloseInterceptor())
                    }
                    .onDisappear {
                        AuthorizationPanelController.shared.dismiss()
                        AuthorizationManager.shared.deny()
                    }
                    #if DEBUG
                    .onChange(of: alwaysOnTop) { _, newValue in
                        if developerModeManager.isDeveloperModeEnabled {
                            applyAlwaysOnTop(newValue)
                        }
                    }
                    #endif

                Color.clear.allowsHitTesting(false)
                    .onChange(of: launchAtLogin) { _, enabled in
                        updateLaunchAtLogin(enabled)
                    }
                if let errorText = modelContainerError {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                    ErrorPopoverView(errorText: errorText) {
                        modelContainerError = nil
                    }
                    .frame(maxWidth: 460, maxHeight: 320)
                    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(radius: 20)
                }

                if let info = infoManager.activeInfo {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                    InfoPopoverView(
                        title: info.title,
                        infoText: info.message
                    ) {
                        infoManager.dismiss()
                    }
                    .frame(maxWidth: 460, maxHeight: 340)
                    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.15), radius: 24, y: 8)
                }

                if updateManager.shouldShowPrompt, let release = updateManager.offeredRelease {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                        .transition(.opacity)
                    UpdatePromptView(
                        currentVersion: updateManager.currentVersion,
                        release: release,
                        onLater: { withAnimation(.easeOut(duration: 0.2)) { updateManager.dismissOffer() } },
                        onUpdate: { withAnimation(.easeOut(duration: 0.2)) { updateManager.prepareOfferedUpdate() } }
                    )
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
                }

                if developerActions.isPickerPresented {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                        .onTapGesture { developerActions.dismissPicker() }
                    DeveloperActionPicker()
                        .environment(developerActions)
                        .frame(minWidth: 540, maxWidth: 640, minHeight: 360, maxHeight: 520)
                        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: .black.opacity(0.15), radius: 24, y: 8)
                }

                }
            }
            }
            .background(OpenWindowStorer())
            .background(MainWindowConfigurator())
            .environment(permissionObserver)
            .environment(permissionsManager)
            .environment(infoManager)
            .environment(aiProviderManager)
            .environment(localCommandExecutor)
            .environment(wakeWordManager)
            .environment(menuBarViewModel)
            .environment(updateManager)
            .environment(sessionStore)
            .environment(nextButtonModel)
            .environment(workspaceStore)
            .environment(iosProfileStore)
            .environment(iosBuildCoordinator)
            .environment(launchCoordinator)
            .environment(sessionWorkspaceLayout)
            .environment(developerActions)
            .environment(ticketWorkflowStore)
            .environment(ticketWorkflowCoordinator)
            #if DEBUG
            .environment(developerModeManager)
            #endif
        }
        .modelContainer(modelContainer)
        .defaultSize(width: 1100, height: 700)
        .windowResizability(.automatic)
        .defaultLaunchBehavior(.presented)
        .onChange(of: scenePhase, initial: true) { _, _ in
            ConsoleWindowManager.openWindow = openWindow
            runAppBootstrapIfNeeded()
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Console") {
                    ConsoleWindowManager.bringToFront("about")
                }
            }
            #if DEBUG
            if developerModeManager.isDeveloperModeEnabled {
                CommandGroup(after: .toolbar) {
                    Toggle("Always on Top", isOn: $alwaysOnTop)
                        .keyboardShortcut("t", modifiers: [.command, .shift])
                }
                CommandMenu("Developer") {
                    @Bindable var devMode = developerModeManager
                    Toggle("Developer Mode", isOn: $devMode.isDeveloperModeEnabled)
                    Divider()
                    Button("Clear User Defaults") {
                        guard let bundleId = Bundle.main.bundleIdentifier else { return }
                        UserDefaults.standard.removePersistentDomain(forName: bundleId)
                    }
                }
            }
            #endif
            CommandGroup(replacing: .windowArrangement) { }
            CommandMenu("Go") {
                // Sidebar destinations on ⌃1…⌃9, in sidebar order.
                ForEach(
                    Array(ConsoleNavigation.sidebarHotkeyDestinations.enumerated()),
                    id: \.offset
                ) { offset, destination in
                    Button(destination.label) {
                        ConsoleNavigation.show(destination)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(offset + 1)")), modifiers: .control)
                }
                Divider()
                Button("Sessions") {
                    ConsoleNavigation.showSessions()
                }
                .keyboardShortcut("`", modifiers: .command)
                // Items stay enabled even without a matching session: the
                // ⌘N contract is "open Sessions, select the Nth session or
                // none", so the shortcut must never be swallowed.
                ForEach(1...ConsoleNavigation.maxSessionHotkeyNumber, id: \.self) { number in
                    Button("Session \(number)") {
                        openHotkeySession(number)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                }
                Button("Focus Session") {
                    guard sessionStore.selectedSession != nil || sessionWorkspaceLayout.isFocusMode else { return }
                    sessionWorkspaceLayout.toggleFocusSession()
                    sessionStore.focusSelectedTerminal()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(sessionStore.selectedSession == nil && !sessionWorkspaceLayout.isFocusMode)
                #if DEBUG
                Divider()
                Button("Refresh Next Task") {
                    nextButtonModel.check(
                        sessionStore: sessionStore,
                        jiraController: JiraWebSession.shared.panelController
                    )
                }
                Button("Open Next Task") {
                    _ = nextButtonModel.performOpen(sessionStore: sessionStore)
                }
                #endif
            }
        }
        .commands {
            CommandMenu("Develop") {
                Button(DeveloperActionID.focusCurrentSession.title) {
                    performDeveloperAction(.focusCurrentSession)
                }
                .disabled(sessionStore.selectedSession == nil && !sessionWorkspaceLayout.isFocusMode)
                .help("Select a session before focusing.")
                Button(DeveloperActionID.newGeneralSession.title) {
                    performDeveloperAction(.newGeneralSession)
                }
                .disabled(workspaceStore.availableWorkspaces.isEmpty)
                .help("Add a workspace folder in Settings → Sessions.")
                Divider()
                Button(DeveloperActionID.openWorkspaceInXcode.title) {
                    performDeveloperAction(.openWorkspaceInXcode)
                }
                .disabled(!isDeveloperActionEnabled(.openWorkspaceInXcode))
                .help(developerActionHelp(.openWorkspaceInXcode))
                Button(DeveloperActionID.buildSelectedProfile.title) {
                    performDeveloperAction(.buildSelectedProfile)
                }
                .disabled(!isDeveloperActionEnabled(.buildSelectedProfile))
                .help(developerActionHelp(.buildSelectedProfile))
                Button(DeveloperActionID.runSelectedTests.title) {
                    performDeveloperAction(.runSelectedTests)
                }
                .disabled(!isDeveloperActionEnabled(.runSelectedTests))
                .help(developerActionHelp(.runSelectedTests))
                Button(DeveloperActionID.openLatestResult.title) {
                    performDeveloperAction(.openLatestResult)
                }
                .disabled(!isDeveloperActionEnabled(.openLatestResult))
                .help(developerActionHelp(.openLatestResult))
                Button(DeveloperActionID.runInSelectedSimulator.title) {
                    performDeveloperAction(.runInSelectedSimulator)
                }
                .disabled(!isDeveloperActionEnabled(.runInSelectedSimulator))
                .help(developerActionHelp(.runInSelectedSimulator))
                Divider()
                Button("Developer Actions…") {
                    developerActions.presentPicker()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            }
        }

        Window("About Console", id: "about") {
            AboutWindowContent()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        Window("Note", id: "note") {
            NoteWindowContent()
                .environment(aiProviderManager)
        }
        .defaultSize(width: 340, height: 340)
        .windowResizability(.contentMinSize)
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            printDebug("Launch at login failed: \(error.localizedDescription)")
        }
    }

    /// ⌘N: jump to the Nth session in store order, or open Sessions with no
    /// session selected when no session corresponds to that number.
    private func openHotkeySession(_ number: Int) {
        if let id = ConsoleNavigation.hotkeySessionID(number: number, in: sessionStore.sessions) {
            sessionStore.select(sessionID: id)
        } else {
            sessionStore.clearSelection()
        }
        ConsoleNavigation.showSessions()
    }

    private var developerActionHosts: DeveloperActionHosts {
        DeveloperActionHosts(
            sessionStore: sessionStore,
            layout: sessionWorkspaceLayout,
            workspaceStore: workspaceStore,
            profileStore: iosProfileStore,
            buildCoordinator: iosBuildCoordinator,
            launchCoordinator: launchCoordinator
        )
    }

    private func performDeveloperAction(_ id: DeveloperActionID) {
        Task { @MainActor in
            let hosts = developerActionHosts
            let snapshot = developerActions.snapshot(hosts: hosts)
            await developerActions.perform(id, snapshot: snapshot, hosts: hosts)
        }
    }

    private func isDeveloperActionEnabled(_ id: DeveloperActionID) -> Bool {
        DeveloperActionCatalog.item(
            for: id,
            in: developerActions.snapshot(hosts: developerActionHosts)
        ).isEnabled
    }

    private func developerActionHelp(_ id: DeveloperActionID) -> String {
        let item = DeveloperActionCatalog.item(
            for: id,
            in: developerActions.snapshot(hosts: developerActionHosts)
        )
        return item.disabledReason ?? item.preview.summary
    }

    private func initializeServices() {
        guard !servicesManager.isInitialized else { return }
        if !Self.isRunningUnitTests {
            AudioCueManager.shared.warmUp()
        }

        let manager = WakeWordManager(modelContext: modelContainer.mainContext)
        wakeWordManager = manager

        localCommandExecutor.modelContext = modelContainer.mainContext

        servicesManager.initialize(
            localCommandExecutor: localCommandExecutor,
            aiProviderManager: aiProviderManager,
            permissionObserver: permissionObserver,
            menuBarViewModel: menuBarViewModel,
            wakeWordManager: manager,
            modelContext: modelContainer.mainContext,
            transcriptSource: syntheticTranscriptSource
        )

        AppDependencies.shared.menuBarViewModel = menuBarViewModel
        AppDependencies.shared.aiProviderManager = aiProviderManager
        AppDependencies.shared.localCommandExecutor = localCommandExecutor

        #if DEBUG
        LogCleanupService.shared.startBackgroundCleanup()
        #endif
    }

    private func handleListenOnStartup() {
        let autoStart = ProcessInfo.processInfo.arguments.contains("--auto-start-listening")
        guard autoStart || UserDefaults.standard.bool(forKey: "listenOnStartup") else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            menuBarViewModel.startListening()
        }
    }

    private func runAppBootstrapIfNeeded() {
        guard !didRunAppBootstrap else { return }
        didRunAppBootstrap = true

        GlobalHotkeyManager.shared.install()
        #if DEBUG
        if developerModeManager.isDeveloperModeEnabled {
            applyAlwaysOnTop(alwaysOnTop)
        }
        #endif

        initializeServices()
        StarterCommandsProvider.loadStarterCommands(into: modelContainer.mainContext)
        StarterCommandsProvider.syncBuiltInPhrases(in: modelContainer.mainContext)
        handleListenOnStartup()
        pingLocalProviderIfNeeded()
        runStartupUpdateCheckIfNeeded()
        sessionStore.startBridgeIfNeeded()
        prepareMorningBriefIfNeeded()
        Task { @MainActor in
            await ticketWorkflowStore.loadProgress()
            if ticketWorkflowStore.persistenceState == .ready {
                ticketWorkflowStore.applyCoordinatorRestartHooks()
            }
        }
    }

    /// Prepares today's Morning Brief at launch so the report is ready
    /// before the user opens the Brief destination for their morning
    /// meeting. Skipped with no registered workspaces so a stub is never
    /// cached over a real one.
    private func prepareMorningBriefIfNeeded() {
        guard !Self.isRunningUnitTests else { return }
        let workspaces = workspaceStore.availableWorkspaces.map(BriefWorkspaceSnapshot.init)
        guard !workspaces.isEmpty else { return }
        Task {
            let attribution = BriefAttributionStore()
            let collector = BriefActivityCollector()
            let sources = await attribution.sources(for: workspaces, probing: collector)
            _ = await BriefGenerationService(collector: collector).ensureBrief(
                for: Date(),
                sources: sources,
                range: attribution.dateRange
            )
        }
    }

    /// One automatic check per process, only in non-test Release builds.
    /// Debug builds and unit tests never auto-check and never see a startup prompt.
    private func runStartupUpdateCheckIfNeeded() {
        #if !DEBUG
        guard !Self.isRunningUnitTests else { return }
        Task { await updateManager.performAutomaticCheckIfNeeded() }
        #endif
    }

    private func pingLocalProviderIfNeeded() {
        guard !Self.isRunningUnitTests else { return }
        Task {
            await aiProviderManager.pingSelectedLocalProviderIfNeeded()
        }
    }

    #if DEBUG
    private func applyAlwaysOnTop(_ enabled: Bool) {
        let level: NSWindow.Level = enabled ? .floating : .normal
        for window in NSApplication.shared.windows where !(window is NSPanel) {
            window.level = level
        }
    }
    #endif

}

// MARK: - Window Helpers

private struct OpenWindowStorer: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { ConsoleWindowManager.openWindow = openWindow }
    }
}

private struct AboutWindowContent: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        AboutView(onClose: { dismiss() })
            .background(AboutWindowConfigurator())
    }
}

private struct NoteWindowContent: View {
    @Environment(AIProviderManager.self) private var aiProviderManager
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var viewModel: NoteViewModel?

    var body: some View {
        Group {
            if let viewModel {
                NotePanelView(viewModel: viewModel)
            } else {
                Color.clear.frame(width: 340, height: 340)
            }
        }
        .background(NoteWindowConfigurator())
        .onAppear {
            let vm = NoteViewModel(aiProviderManager: aiProviderManager)
            NoteViewModel.shared = vm
            viewModel = vm
            NotePanelController.shared.windowOpened(viewModel: vm, aiProviderManager: aiProviderManager)
            NotePanelController.shared.dismissAction = { [dismissWindow] in
                dismissWindow(id: "note")
            }
        }
        .onDisappear {
            NotePanelController.shared.windowClosed()
            viewModel = nil
        }
    }
}

private struct NoteWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NoteConfigView()
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class NoteConfigView: NSView {
    private static let frameKey = "noteWindowFrame"
    private var didConfigure = false
    private var observers: [NSObjectProtocol] = []
    private weak var pinButton: NSButton?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !didConfigure, let window else { return }
        didConfigure = true

        window.level = .normal
        window.isOpaque = false
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.transient, .moveToActiveSpace]

        DispatchQueue.main.async {
            window.backgroundColor = .white
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true

            let symbolConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            let accentColor = NSColor(named: "AccentColor") ?? .controlAccentColor

            let pinButton = NSButton(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
            pinButton.bezelStyle = .inline
            pinButton.isBordered = false
            pinButton.contentTintColor = accentColor
            pinButton.target = self
            pinButton.action = #selector(self.togglePin)
            self.pinButton = pinButton
            self.updatePinButtonAppearance()

            let closeButton = NSButton(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
            closeButton.bezelStyle = .inline
            closeButton.isBordered = false
            closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
                .withSymbolConfiguration(symbolConfig)
            closeButton.contentTintColor = accentColor
            closeButton.target = self
            closeButton.action = #selector(self.closeNoteWindow)

            let rightGroup = NSStackView(views: [pinButton, closeButton])
            rightGroup.orientation = .horizontal
            rightGroup.spacing = 4
            rightGroup.alignment = .centerY
            rightGroup.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 8)
            rightGroup.frame.size = rightGroup.fittingSize

            let rightAccessory = NSTitlebarAccessoryViewController()
            rightAccessory.view = rightGroup
            rightAccessory.layoutAttribute = .right
            window.addTitlebarAccessoryViewController(rightAccessory)

            let noteLabel = NSTextField(labelWithString: "Note")
            noteLabel.font = .systemFont(ofSize: 13, weight: .semibold)
            noteLabel.textColor = accentColor
            noteLabel.translatesAutoresizingMaskIntoConstraints = false

            let leftContainer = NSView(frame: NSRect(
                x: 0,
                y: 0,
                width: max(40, noteLabel.intrinsicContentSize.width + 2),
                height: 22
            ))
            leftContainer.addSubview(noteLabel)
            NSLayoutConstraint.activate([
                noteLabel.leadingAnchor.constraint(equalTo: leftContainer.leadingAnchor),
                noteLabel.trailingAnchor.constraint(equalTo: leftContainer.trailingAnchor),
                noteLabel.centerYAnchor.constraint(equalTo: leftContainer.centerYAnchor)
            ])

            let leftAccessory = NSTitlebarAccessoryViewController()
            leftAccessory.view = leftContainer
            leftAccessory.layoutAttribute = .left
            window.addTitlebarAccessoryViewController(leftAccessory)
        }

        if let saved = UserDefaults.standard.string(forKey: Self.frameKey) {
            let frame = NSRectFromString(saved)
            let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
            if onScreen && frame.width > 0 && frame.height > 0 {
                window.setFrame(frame, display: true)
            } else {
                applyDefaultPosition(to: window)
            }
        } else {
            applyDefaultPosition(to: window)
        }

        let saveHandler: (Notification) -> Void = { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            self?.saveFrame(window.frame)
        }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main, using: saveHandler))
        observers.append(nc.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main, using: saveHandler))
        observers.append(nc.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main, using: saveHandler))

        window.makeKeyAndOrderFront(nil)
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    @objc private func closeNoteWindow() {
        NotePanelController.shared.dismiss()
    }

    @objc private func togglePin() {
        guard let viewModel = NoteViewModel.shared else { return }
        viewModel.togglePin()
        updatePinButtonAppearance()
    }

    private func updatePinButtonAppearance() {
        guard let pinButton else { return }
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        let isPinned = NoteViewModel.shared?.isPinned == true
        let symbolName = isPinned ? "square.3.layers.3d.top.filled" : "square.3.layers.3d"
        pinButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Pin")?
            .withSymbolConfiguration(symbolConfig)
        pinButton.alphaValue = isPinned ? 1.0 : 0.5
    }

    private func applyDefaultPosition(to window: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let windowSize = window.frame.size
        let x = visible.maxX - windowSize.width - 50
        let y = visible.midY - windowSize.height / 2
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func saveFrame(_ frame: NSRect) {
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.frameKey)
    }
}

private struct MainWindowConfigurator: NSViewRepresentable {
    private func configure(window: NSWindow?) {
        guard let window else { return }
        window.level = .normal
        window.collectionBehavior = [.transient, .moveToActiveSpace]

        // Register with the window manager so the global hotkey can raise it reliably
        // without depending on fragile NSWindow identifier matching.
        ConsoleWindowManager.mainWindow = window

        if let panel = window as? NSPanel {
            panel.isFloatingPanel = false
            panel.hidesOnDeactivate = false
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(window: nsView.window)
        }
    }
}

private struct AboutWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.level = .floating
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.level = .floating
        }
    }
}
