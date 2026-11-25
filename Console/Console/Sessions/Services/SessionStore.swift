import AppKit
import Foundation
import SwiftTerm

enum SessionCreationError: LocalizedError, Equatable {
    case claudeNotFound
    case pluginAssemblyFailed
    case sessionLaunchFailed
    case orchestratorChildLimitReached(limit: Int)

    var errorDescription: String? {
        switch self {
        case .claudeNotFound:
            return "Claude Code was not found on this Mac. Install Claude Code or pick its executable in Settings → Claude Executable."
        case .pluginAssemblyFailed:
            return "Console could not prepare the local bridge for this session. The terminal will still work, but session status is unavailable."
        case .sessionLaunchFailed:
            return "Console could not start Claude for this session. Check the executable path in Settings → Claude Executable."
        case .orchestratorChildLimitReached(let limit):
            return "child limit reached (\(limit))"
        }
    }
}

/// The owned process set captured when a stop starts: the PTY root plus its
/// descendants, each with a pid+start-time identity. Captured BEFORE any
/// signal because the root's death reparents descendants, and because a
/// recycled PID must never become a later kill target.
struct SessionStopTarget: Equatable {
    let root: SessionProcessIdentity
    let descendants: [SessionProcessIdentity]
}

/// App-owned observable store for all Console Claude sessions.
///
/// Terminal views are memory-only; launch metadata and process identities survive
/// app termination so leftover processes can be recovered safely.
@MainActor
@Observable
final class SessionStore {
    private(set) var sessions: [ConsoleSession] = []
    private(set) var selectedSessionID: UUID?
    private(set) var awaitingForceStopSessionID: UUID?
    private(set) var pendingRestorations: [SessionRestorationRecord] = []
    private(set) var isRestoringSessions = false
    /// Process-only dismissal; saved restoration records remain untouched.
    private var isRestoreSessionsSidebarDismissed = false
    private(set) var restorationMessage: String?
    private(set) var restorationPersistenceError: String?
    private(set) var headlessSessions: [HeadlessSession] = []
    private(set) var headlessActionID: SessionProcessIdentity?
    private(set) var headlessMessage: String?
    @ObservationIgnored private let processInspector: any SessionProcessInspecting
    @ObservationIgnored private var isScanningProcesses = false
    #if DEBUG
    @ObservationIgnored private var headlessPreviewMode = false
    #endif
    @ObservationIgnored private let restorationStore: SessionRestorationStore?
    private(set) var recentlyClosedSessions: [SessionRestorationRecord] = []
    @ObservationIgnored private var savedSnapshot = SessionRestorationSnapshot()
    @ObservationIgnored private var isTerminating = false
    @ObservationIgnored private var restorationLoadFailed = false
    @ObservationIgnored private var startingRestorations: [UUID: SessionRestorationRecord] = [:]

    var canRestoreSessions: Bool {
        !pendingRestorations.isEmpty && !isRestoringSessions && !isTerminating && headlessActionID == nil
    }

    var isRestoreSessionsSidebarVisible: Bool {
        !pendingRestorations.isEmpty && !isRestoreSessionsSidebarDismissed
    }

    func dismissRestoreSessionsSidebar() {
        isRestoreSessionsSidebarDismissed = true
    }
    /// Sessions the user terminated; closed (removed) as soon as their
    /// process exits instead of lingering as dead terminals.
    @ObservationIgnored private var closeOnExitIDs: Set<UUID> = []
    /// Captured stop targets per session, retained across the grace period so
    /// escalation and force stop never re-read a terminal PID that may have
    /// been recycled or replaced.
    @ObservationIgnored private var stopTargets: [UUID: SessionStopTarget] = [:]

    @ObservationIgnored let locator: ClaudeExecutableLocator
    @ObservationIgnored private var launcher: any SessionProcessLaunching
    @ObservationIgnored private let pluginAssembler: any ConsoleClaudePluginAssembling
    /// Durable work identity shared by Home, history, and MR session routing.
    @ObservationIgnored let associations: SessionAssociationStore
    private(set) var associationPersistenceError: String?

    // Bridge plumbing. Tokens and event ids live only in memory.
    @ObservationIgnored private var sessionTokens: [UUID: String] = [:]
    @ObservationIgnored private var router: SessionEventRouter!
    @ObservationIgnored private var socketServer: SessionBridgeSocketServer?
    @ObservationIgnored private var socketPath: String?

    /// Ephemeral root shared by the socket and assembled plugin copies.
    @ObservationIgnored private let ephemeralRoot: URL
    @ObservationIgnored private var assembledPluginRoot: URL?
    @ObservationIgnored private var inputMonitor: Any?
    /// Captured login-shell environment for session launches; nil until the
    /// first capture attempt, which happens at first session creation.
    @ObservationIgnored private var cachedLoginShellEnvironment: [String: String]?
    @ObservationIgnored private var didCaptureLoginShellEnvironment = false
    /// Injectable so tests can stage a failed capture followed by success.
    @ObservationIgnored var loginShellEnvironmentCapture: () -> [String: String]? = {
        SessionEnvironmentBuilder.captureLoginShellEnvironment()
    }
    /// Answers whether the user is literally looking at a session right now:
    /// the app is active, the session is selected, and keyboard focus sits in
    /// its terminal view. Injectable so tests can stage focus without windows.
    @ObservationIgnored var viewingFocusDetector: @MainActor (UUID) -> Bool = { _ in false }

    static let gracefulStopGraceSeconds: UInt64 = 3
    static let maxOrchestratorChildren = 4

    init(
        launcher: any SessionProcessLaunching,
        locator: ClaudeExecutableLocator,
        pluginAssembler: any ConsoleClaudePluginAssembling = ConsoleClaudePluginAssembler(),
        restorationStore: SessionRestorationStore? = nil,
        processInspector: any SessionProcessInspecting = HeadlessSessionProcesses(),
        ticketAssociations: SessionTicketAssociations = SessionTicketAssociations()
    ) {
        self.launcher = launcher
        self.locator = locator
        self.pluginAssembler = pluginAssembler
        self.restorationStore = restorationStore
        self.processInspector = processInspector
        self.associations = SessionAssociationStore(url: restorationStore?.url.deletingLastPathComponent()
            .appendingPathComponent("SessionAssociations.json"), legacyTickets: ticketAssociations.allKeys())
        associationPersistenceError = associations.persistenceError
        if let restorationStore {
            do {
                savedSnapshot = try restorationStore.load()
                pendingRestorations = savedSnapshot.sessions
                recentlyClosedSessions = savedSnapshot.recentlyClosed ?? []
                watchedConversations = Set(savedSnapshot.watchedConversations ?? [])
                recheckDue = savedSnapshot.recheckDue
                readOnlyConversations = savedSnapshot.readOnlyConversations ?? []
            } catch {
                restorationLoadFailed = true
                restorationPersistenceError = "Saved sessions could not be read: \(error.localizedDescription)"
            }
        }
        ephemeralRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("console-sessions-\(UUID().uuidString)", isDirectory: true)
        router = SessionEventRouter(
            apply: { [weak self] sessionID, envelope in
                self?.handleValidatedEnvelope(sessionID: sessionID, envelope: envelope)
            },
            tokenForSession: { [weak self] sessionID in
                self?.sessionTokens[sessionID]
            }
        )
        viewingFocusDetector = { [weak self] sessionID in
            self?.isViewingFocus(sessionID: sessionID) ?? false
        }
        if restorationStore != nil {
            Task { [weak self] in await self?.refreshHeadlessSessions() }
        }
    }

    convenience init(launcher: any SessionProcessLaunching) {
        self.init(launcher: launcher, locator: ClaudeExecutableLocator())
    }

    convenience init() {
        self.init(launcher: ClaudeSessionLauncher(), locator: ClaudeExecutableLocator(),
                  restorationStore: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
                    && !ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("-uiTest") })
                    && ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1"
                    ? .standard : nil)
    }

    /// Starts bridge instrumentation. Failure is non-fatal by design.
    func startBridgeIfNeeded() {
        guard socketServer == nil else { return }
        installInputMonitorIfNeeded()

        guard let socketURL = SessionBridgeSocketServer.makeProtectedSocketURL() else {
            markBridgeUnavailable()
            return
        }
        let server = SessionBridgeSocketServer(socketPath: socketURL.path) { [weak self] data in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.router.receive(rawData: data)
                }
            }
        }
        if server.start() {
            socketServer = server
            socketPath = socketURL.path
        } else {
            markBridgeUnavailable()
        }
    }

    private func markBridgeUnavailable() {
        // Instrumentation unavailable; sessions remain fully usable.
        for index in sessions.indices where sessions[index].bridgeStatus == .unknown {
            sessions[index].bridgeStatus = .unavailable
        }
    }

    /// Optimistic attention clearing: any key press delivered to the selected
    /// session's terminal clears permission/question attention immediately.
    private func installInputMonitorIfNeeded() {
        guard inputMonitor == nil else { return }
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self,
                  let window = event.window,
                  let firstResponder = window.firstResponder as? NSView,
                  let selected = self.selectedSession,
                  firstResponder.isDescendant(of: selected.terminalView) else {
                return event
            }
            self.noteUserInput(sessionID: selected.id)
            return event
        }
    }

    /// Stops bridge instrumentation (app termination only).
    func stopBridge() {
        socketServer?.stop()
        socketServer = nil
    }

    // MARK: - Creation

    var selectedSession: ConsoleSession? {
        sessions.first(where: { $0.id == selectedSessionID })
    }

    /// True when the bridge socket server is running, so lifecycle events
    /// (including `sessionStarted`) can be expected.
    var isBridgeInstrumented: Bool { socketServer != nil }

    /// Observer fired after each reduced lifecycle event is applied.
    @ObservationIgnored var lifecycleObserver: (@MainActor (UUID, SessionLifecycleEvent) -> Void)?

    /// Additional subscribers (Ticket Work, etc.). The primary
    /// `lifecycleObserver` is preserved; subscribers are fan-out only.
    @ObservationIgnored private var lifecycleSubscribers:
        [UUID: @MainActor (UUID, SessionLifecycleEvent) -> Void] = [:]

    @discardableResult
    func addLifecycleSubscriber(
        _ handler: @escaping @MainActor (UUID, SessionLifecycleEvent) -> Void
    ) -> UUID {
        let id = UUID()
        lifecycleSubscribers[id] = handler
        return id
    }

    func removeLifecycleSubscriber(_ id: UUID) {
        lifecycleSubscribers.removeValue(forKey: id)
    }

    private func notifyLifecycle(sessionID: UUID, event: SessionLifecycleEvent) {
        lifecycleObserver?(sessionID, event)
        for subscriber in lifecycleSubscribers.values {
            subscriber(sessionID, event)
        }
    }

    #if DEBUG
    /// Test seam: bytes handed to SwiftTerm `send`, in order. Never used at runtime.
    @ObservationIgnored private(set) var debugTerminalSendBytes: [(sessionID: UUID, utf8: String)] = []
    #endif

    func session(withID id: UUID) -> ConsoleSession? {
        sessions.first(where: { $0.id == id })
    }

    /// Puts keyboard focus on the selected session's persistent terminal view.
    /// Safe when the view is temporarily unmounted or has no window yet.
    func focusSelectedTerminal() {
        guard let terminalView = selectedSession?.terminalView else { return }
        DispatchQueue.main.async {
            terminalView.window?.makeFirstResponder(terminalView)
        }
    }

    /// A freshly created session's terminal claims keyboard focus as soon as it
    /// mounts, so the user can type into the new session without clicking.
    /// Only creation arms this; selecting an existing session must not steal
    /// focus from whatever the user is doing.
    private func armTerminalFocus(_ terminalView: LocalProcessTerminalView) {
        (terminalView as? ConsoleTerminalView)?.claimsFocusOnWindowAttach = true
    }

    func displayedState(for sessionID: UUID) -> DisplayedSessionState {
        guard let session = session(withID: sessionID) else { return .unknown }
        return displayedSessionState(activity: session.activity, attention: session.attention)
    }

    /// Suggested name from a chosen folder with duplicate-active-name suffixing.
    func suggestedName(for directory: URL) -> String {
        Self.uniquedName(Self.baseName(of: directory), existingNames: activeNames)
    }

    var activeNames: [String] {
        sessions.map(\.name)
    }

    static func baseName(of directory: URL) -> String {
        let name = directory.lastPathComponent
        return name.isEmpty ? "/" : name
    }

    /// `Folder`, `Folder 2`, `Folder 3`, … against names already in use.
    static func uniquedName(_ base: String, existingNames: [String]) -> String {
        let taken = Set(existingNames)
        guard taken.contains(base) else { return base }
        var counter = 2
        while taken.contains("\(base) \(counter)") {
            counter += 1
        }
        return "\(base) \(counter)"
    }

    /// Creates and launches a new Claude session from a typed launch request.
    /// `request.name` is the local Console label only; it is not passed to
    /// Claude. Source metadata is never placed in argv, environment, or
    /// terminal-send bytes.
    @discardableResult
    func createSession(request: SessionCreationRequest) throws -> UUID {
        let sessionID = try createSession(request: request, resuming: nil)
        // A brand-new session supersedes whatever was saved from a previous
        // launch: retire the restore offer so the sidebar row disappears and
        // the saved snapshot holds only the work the user has actually started.
        // Background launches are Console's work, not the user's, so they keep it.
        if request.revealsSession { invalidateSavedRestorations() }
        return sessionID
    }

    /// Drops the restore offer for sessions saved before this launch. Resuming
    /// goes through `resumeSession(from:)` instead, which keeps the offer.
    private func invalidateSavedRestorations() {
        guard !pendingRestorations.isEmpty else { return }
        pendingRestorations.removeAll()
        savedSnapshot = SessionRestorationSnapshot()
        persistRestorationSnapshot()
    }

    private func createSession(request: SessionCreationRequest, resuming record: SessionRestorationRecord?) throws -> UUID {
        if request.purpose == .orchestrator,
           let existing = orchestratorSession(), existing.activity != .exited,
           record == nil || record?.id == existing.claudeSessionID {
            if request.revealsSession { select(sessionID: existing.id) }
            return existing.id
        }
        let parentClaudeSessionID = record?.parentClaudeSessionID ?? request.parentClaudeSessionID
        try checkChildCapacity(parentClaudeSessionID: parentClaudeSessionID)
        if request.purpose == .blank {
            return try createBlankSession(request: request, resuming: record, parentClaudeSessionID: parentClaudeSessionID)
        }
        guard let claudePath = locator.locate() else {
            throw SessionCreationError.claudeNotFound
        }

        startBridgeIfNeeded()

        let consoleID = UUID()
        let claudeID = record?.claudeSessionID ?? UUID()
        let model = record?.model ?? request.model
        let toolProfile: SessionToolProfile = if let record {
            record.readOnly == true || readOnlyConversations.contains(record.claudeSessionID)
                ? .readOnlyPrep(contextDirectory: request.workingDirectory) : .standard
        } else {
            request.toolProfile
        }
        let displayName = request.purpose == .orchestrator
            ? SessionPurpose.orchestrator.defaultName(source: nil)
            : Self.uniquedName(request.name.trimmingCharacters(in: .whitespacesAndNewlines), existingNames: activeNames)

        let terminalView = launcher.makeTerminalView()

        let coordinator = SessionTerminalCoordinator(sessionID: consoleID, store: self)
        terminalView.processDelegate = coordinator
        (terminalView as? ConsoleTerminalView)?.retainedSessionCoordinator = coordinator
        if request.revealsSession { armTerminalFocus(terminalView) }

        // Plugin/bridge preparation is optional. A failure of either the
        // plugin assembly or the socket/server still launches the resolved
        // Claude executable without unusable plugin arguments.
        let pluginRoot = materializePluginRoot()
        let token: String?
        let arguments: [String]
        var environment: [String: String]
        let bridgeStatus: BridgeStatus
        let instrumentationWarning: String?

        if let pluginRoot, isBridgeInstrumented, socketPath != nil {
            let sessionToken = Self.generateToken()
            token = sessionToken
            arguments = Self.launchArguments(
                claudeSessionID: claudeID,
                pluginDirectory: pluginRoot.path,
                resume: record != nil,
                agent: Self.agent(for: request),
                model: model,
                toolProfile: toolProfile,
                isOrchestrator: request.purpose == .orchestrator
            )
            environment = childEnvironment(
                bridgeEnvironment: [
                    "CONSOLE_TERM_BRIDGE_HELPER": Self.helperPath(),
                    "CONSOLE_TERM_BRIDGE_SOCKET": socketPath ?? "",
                    "CONSOLE_TERM_BRIDGE_SESSION_ID": consoleID.uuidString,
                    "CONSOLE_TERM_BRIDGE_TOKEN": sessionToken,
                    "CONSOLE_SESSIONS_SNAPSHOT": sessionsSnapshotPath() ?? "",
                    "CONSOLE_MCP_RESULTS_DIR": mcpResultsDirectoryURL()?.path ?? "",
                ]
            )
            // Unknown until a validated envelope arrives; never start as active.
            bridgeStatus = .unknown
            instrumentationWarning = nil
        } else {
            token = nil
            arguments = Self.launchArguments(
                claudeSessionID: claudeID,
                pluginDirectory: nil,
                resume: record != nil,
                agent: Self.agent(for: request),
                model: model,
                toolProfile: toolProfile,
                isOrchestrator: request.purpose == .orchestrator
            )
            environment = childEnvironment(bridgeEnvironment: [:])
            bridgeStatus = .unavailable
            instrumentationWarning = SessionCreationError.pluginAssemblyFailed.errorDescription
        }

        // Present even when bridge assembly fails; child tools cannot be mistaken
        // for Claude because discovery also checks the executable and session argv.
        environment[HeadlessSessionProcesses.sessionEnvironmentKey] = claudeID.uuidString

        var session = ConsoleSession(
            id: consoleID,
            claudeSessionID: claudeID,
            name: displayName,
            workingDirectory: request.workingDirectory,
            terminalView: terminalView,
            activity: .starting,
            attention: .none,
            summary: nil,
            artifacts: associations.artifacts(for: claudeID) + Self.initialArtifacts(for: request.source)
                + (request.purpose == .newTicket && SessionTicketClassification.consoleStoryName(request.name)
                    ? [.init(kind: .jiraIssue, label: request.name)] : []),
            bridgeStatus: bridgeStatus,
            purpose: request.purpose,
            instrumentationWarning: instrumentationWarning,
            parentClaudeSessionID: parentClaudeSessionID
        )

        session.model = model
        session.toolProfile = toolProfile
        if toolProfile != .standard, !readOnlyConversations.contains(claudeID) {
            readOnlyConversations = Array((readOnlyConversations + [claudeID]).suffix(500))
        }
        let previousSelection = selectedSessionID
        insertSession(session)
        if let token {
            sessionTokens[consoleID] = token
        }
        if request.revealsSession { selectedSessionID = consoleID }
        if let record { startingRestorations[consoleID] = record }

        do {
            try launcher.launch(
                executable: claudePath,
                arguments: arguments,
                environment: environment,
                workingDirectory: request.workingDirectory.path,
                terminalView: terminalView
            )
        } catch {
            sessions.removeAll { $0.id == consoleID }
            sessionTokens.removeValue(forKey: consoleID)
            startingRestorations.removeValue(forKey: consoleID)
            selectedSessionID = previousSelection
            writeSessionsSnapshot()
            throw error
        }
        // Commit the replacement only after launch succeeds. Closing also stops
        // the previous process and removes its bridge and queued directives.
        if request.purpose == .orchestrator {
            for previous in sessions.filter({ $0.purpose == .orchestrator && $0.id != consoleID }) {
                closeSession(id: previous.id)
            }
        }
        if let record { pendingRestorations.removeAll { $0.id == record.id } }
        rememberAssociation(for: session)
        persistRestorationSnapshot()
        return consoleID
    }

    /// Blank sessions run a plain login shell as their PTY child — no Claude
    /// executable, plugin, or bridge instrumentation. The saved restoration
    /// identity is kept so a restored Blank row reopens as a fresh shell in
    /// the same folder.
    private func createBlankSession(request: SessionCreationRequest, resuming record: SessionRestorationRecord?,
                                    parentClaudeSessionID: UUID?) throws -> UUID {
        let consoleID = UUID()
        let claudeID = record?.claudeSessionID ?? UUID()
        let displayName = Self.uniquedName(request.name.trimmingCharacters(in: .whitespacesAndNewlines), existingNames: activeNames)

        let terminalView = launcher.makeTerminalView()
        let coordinator = SessionTerminalCoordinator(sessionID: consoleID, store: self)
        terminalView.processDelegate = coordinator
        (terminalView as? ConsoleTerminalView)?.retainedSessionCoordinator = coordinator
        if request.revealsSession { armTerminalFocus(terminalView) }

        let session = ConsoleSession(
            id: consoleID,
            claudeSessionID: claudeID,
            name: displayName,
            workingDirectory: request.workingDirectory,
            terminalView: terminalView,
            activity: .starting,
            attention: .none,
            summary: nil,
            artifacts: [],
            bridgeStatus: .unavailable,
            purpose: request.purpose,
            instrumentationWarning: nil,
            parentClaudeSessionID: parentClaudeSessionID
        )

        let previousSelection = selectedSessionID
        insertSession(session)
        if request.revealsSession { selectedSessionID = consoleID }
        if let record { startingRestorations[consoleID] = record }

        do {
            try launcher.launchShell(
                workingDirectory: request.workingDirectory.path,
                environment: childEnvironment(bridgeEnvironment: [:]),
                terminalView: terminalView
            )
        } catch {
            sessions.removeAll { $0.id == consoleID }
            startingRestorations.removeValue(forKey: consoleID)
            selectedSessionID = previousSelection
            writeSessionsSnapshot()
            throw error
        }
        if let record { pendingRestorations.removeAll { $0.id == record.id } }
        persistRestorationSnapshot()
        return consoleID
    }

    /// Initial informational chips for a launch's source context so the row
    /// shows its ticket/MR immediately, before any bridge artifacts arrive.
    static func initialArtifacts(for source: SessionLaunchSource?) -> [SessionArtifact] {
        guard let source else { return [] }
        return [SessionArtifact(kind: source.artifactKind, label: source.artifactLabel, url: source.artifactURL)]
    }

    /// Legacy creation entry point retained for compatibility; equivalent to
    /// a General-purpose request with no source context.
    @discardableResult
    func createSession(name: String, workingDirectory: URL) throws -> UUID {
        try createSession(
            request: SessionCreationRequest(
                purpose: .general,
                name: name,
                workingDirectory: workingDirectory
            )
        )
    }

    /// Typed resume entry point: reopens a previous Claude conversation with
    /// `claude --resume <session-id>` in a fresh Console terminal at the
    /// conversation's recorded working directory. Bridge instrumentation and
    /// rollback behave exactly like a fresh launch.
    @discardableResult
    func resumeSession(from record: SessionRestorationRecord) throws -> UUID {
        try createSession(
            request: SessionCreationRequest(
                purpose: record.purpose,
                name: record.name,
                workingDirectory: record.workingDirectory
            ),
            resuming: record
        )
    }

    /// Claude Code agent Self Review / Agent Review launches request explicitly.
    /// Not applied as a silent purpose default — missing agents fail the child.
    static let reviewAgentName = "agent-review"

    /// Claude Code agent Home's Next-up "Start story" launches run under. The
    /// agent is expected to exist in the user's Claude configuration.
    static let newStoryAgentName = "agent-nhl"

    /// The agent a launch runs under. Only an explicit request agent is used;
    /// review purpose alone does not imply `--agent agent-review`.
    static func agent(for request: SessionCreationRequest) -> String? {
        request.agent
    }

    /// Exact launch arguments: Claude session identity with bypassed
    /// permission prompts, an optional named agent, and when a plugin
    /// directory is available the bundled plugin plus preapproval of only the
    /// Console MCP tool names. The local Console display name is omitted
    /// — it must not reach the child CLI. Uninstrumented launches pass identity
    /// only so a missing plugin cannot block Claude.
    ///
    /// A `.readOnlyPrep` profile replaces the bypass with `dontAsk`, limits the
    /// built-in tools to Read/Grep/Glob, denies every MCP tool (plugin servers
    /// load even under `--strict-mcp-config`), and preapproves nothing. The
    /// bridge plugin still loads: its hooks report lifecycle, only its MCP
    /// tools are denied.
    static func launchArguments(
        claudeSessionID: UUID,
        pluginDirectory: String?,
        resume: Bool = false,
        agent: String? = nil,
        model: String? = nil,
        toolProfile: SessionToolProfile = .standard,
        isOrchestrator: Bool = false
    ) -> [String] {
        var arguments = [resume ? "--resume" : "--session-id", claudeSessionID.uuidString]
        if let model { arguments += ["--model", model] }
        // The Orchestrator manages work and never does it. The tools that do
        // work are removed at launch, so this does not rest on its prompt.
        if isOrchestrator { arguments += ["--disallowedTools"] + orchestratorDeniedTools }
        switch toolProfile {
        case .standard:
            arguments.append("--dangerously-skip-permissions")
            if let agent {
                arguments += ["--agent", agent]
            }
            if let pluginDirectory {
                arguments += ["--plugin-dir", pluginDirectory]
                arguments += ["--allowedTools"] + ConsoleClaudePluginAssembler.allowedToolNames
            }
        case .readOnlyPrep(let contextDirectory):
            arguments += ["--permission-mode", "dontAsk"]
            arguments += ["--tools"] + readOnlyPrepTools
            arguments += ["--disallowedTools"] + readOnlyPrepDeniedTools
            arguments += ["--strict-mcp-config"]
            arguments += ["--add-dir", contextDirectory.path]
            if let pluginDirectory {
                arguments += ["--plugin-dir", pluginDirectory]
            }
        }
        return arguments
    }

    /// Tools the Orchestrator never has: running commands, editing files, and
    /// in-process subagents. It keeps Read/Grep/Glob for briefs and session
    /// context, and Write only to stage a child's brief file.
    static let orchestratorDeniedTools = ["Bash", "Edit", "NotebookEdit", "Agent", "Task"]

    /// The only built-in tools a read-only prep session has.
    static let readOnlyPrepTools = ["Read", "Grep", "Glob"]

    /// Denied even if the user's own settings allow them. `--tools` already
    /// removes the built-ins; the deny list is the backstop.
    static let readOnlyPrepDeniedTools = [
        "Bash", "Edit", "Write", "NotebookEdit", "WebFetch", "WebSearch", "Agent", "Task", "mcp__*",
    ]

    /// Environment for a session launch: Console's environment layered with
    /// terminal defaults and the cached login-shell snapshot (matching the
    /// drawer's `zsh --login`), with bridge identity variables always winning.
    private func childEnvironment(bridgeEnvironment: [String: String]) -> [String: String] {
        SessionEnvironmentBuilder.childEnvironment(
            base: ProcessInfo.processInfo.environment,
            loginShellEnvironment: loginShellEnvironment(),
            bridge: bridgeEnvironment
        ).filterEnvironmentValues()
    }

    /// The login-shell environment is captured once per process; a failed
    /// capture is retried on the next session creation.
    private func loginShellEnvironment() -> [String: String]? {
        if didCaptureLoginShellEnvironment {
            return cachedLoginShellEnvironment
        }
        guard let captured = loginShellEnvironmentCapture() else {
            return nil
        }
        didCaptureLoginShellEnvironment = true
        cachedLoginShellEnvironment = captured
        return captured
    }

    /// Best-effort plugin copy. Failure is non-fatal: the caller launches
    /// Claude without plugin or bridge arguments instead of aborting.
    private func materializePluginRoot() -> URL? {
        if let existing = assembledPluginRoot {
            return existing
        }
        do {
            let root = try pluginAssembler.materialize(in: ephemeralRoot)
            assembledPluginRoot = root
            return root
        } catch {
            return nil
        }
    }

    private static func helperPath() -> String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ConsoleTermBridge").path
    }

    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Selection / lifecycle

    func select(sessionID: UUID) {
        selectedSessionID = sessionID
        // Navigating to a session is seeing it: any pending completion
        // notification for it clears. Outstanding input requests (permission,
        // question) are never cleared by viewing.
        acknowledgeCompletion(sessionID: sessionID)
        persistRestorationSnapshot()
    }

    /// Renames the session locally and keeps the running Claude Code session
    /// in sync by sending `/rename <name>` (the stored name is the uniqued
    /// one, so the terminal shows exactly what Console displays). Exited
    /// sessions reject the command and only rename locally.
    func renameSession(id: UUID, name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].name = Self.uniquedName(
            trimmedName,
            existingNames: sessions.filter { $0.id != id }.map(\.name)
        )
        persistRestorationSnapshot()
        sendRenameCommand(sessions[index].name, to: id)
    }

    /// The toolbar follows the Sessions list's stable store order.
    var sessionsNeedingAttention: [ConsoleSession] {
        sessions.filter {
            let state = displayedSessionState(activity: $0.activity, attention: $0.attention)
            return HomeSessionsPresentation.needsYou(state) || state == .done
        }
    }

    /// Viewing acknowledges a completion, never an outstanding input request.
    func acknowledgeCompletion(sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
              sessions[index].attention == .unreadCompletion else { return }
        sessions[index].attention = .none
        writeSessionsSnapshot()
    }

    /// Drops the selection so the Sessions destination shows its empty pane.
    /// Used by the ⌃0 / out-of-range session hotkeys.
    func clearSelection() {
        selectedSessionID = nil
        persistRestorationSnapshot()
    }

    /// Graceful stop (SIGTERM). The UI's Terminate flow (`terminateSession`)
    /// confirms first for Working / Needs Approval / Needs Input sessions and
    /// calls this afterwards; plain stops retain the exited session row.
    ///
    /// The whole owned set is signaled, not just the PTY root: a Claude
    /// resumed from the retained login shell is a descendant of the root with
    /// its own foreground process group, and an interactive zsh ignores
    /// SIGTERM, so signaling the root alone never reaches it. Identities are
    /// captured before the first signal and reused by escalation.
    func stopSession(id: UUID) {
        guard let session = session(withID: id), session.activity != .exited else { return }
        awaitingForceStopSessionID = nil
        let pid = session.terminalView.process?.shellPid ?? 0
        guard pid > 0, let target = captureStopTarget(rootPID: pid) else {
            handleProcessTerminated(sessionID: id)
            return
        }
        stopTargets[id] = target
        HeadlessSessionProcesses.signalAttached([target.root] + target.descendants, SIGTERM)
        scheduleOwnedStopEscalation(id: id, target: target)
    }

    /// Force stop (SIGKILL). Liveness, not the activity flag, decides: a
    /// session marked exited by a bridge event can still own a live process.
    /// The captured stop target outranks the terminal's current PID, which may
    /// belong to a recycled or replaced process.
    func forceStop(id: UUID) {
        awaitingForceStopSessionID = nil
        guard let session = session(withID: id) else { return }
        guard let target = stopTargets[id] ?? freshStopTarget(for: session) else {
            handleProcessTerminated(sessionID: id)
            return
        }
        let alive = aliveOwnedIdentities(of: target)
        // A process that no longer exists needs nothing; zombies included.
        guard !alive.isEmpty else { return }
        HeadlessSessionProcesses.signalAttached(alive, SIGKILL)
    }

    private func freshStopTarget(for session: ConsoleSession) -> SessionStopTarget? {
        guard let pid = session.terminalView.process?.shellPid, pid > 0 else { return nil }
        return captureStopTarget(rootPID: pid)
    }

    private func captureStopTarget(rootPID: pid_t) -> SessionStopTarget? {
        guard let root = HeadlessSessionProcesses.identity(for: rootPID) else { return nil }
        return SessionStopTarget(
            root: root,
            descendants: OwnedProcessTree.descendantIDs(of: rootPID)
                .compactMap { HeadlessSessionProcesses.identity(for: $0) }
        )
    }

    /// Owned identities that are still alive, validated against their
    /// captured pid+start-time identities. While the root lives, descendants
    /// spawned after the capture are picked up too; once the root is gone its
    /// former descendants are reparented, so only the captured identities
    /// remain addressable.
    private func aliveOwnedIdentities(of target: SessionStopTarget) -> [SessionProcessIdentity] {
        var candidates = target.descendants
        if processInspector.isRunning(target.root) {
            candidates += OwnedProcessTree.descendantIDs(of: target.root.pid)
                .compactMap { HeadlessSessionProcesses.identity(for: $0) }
        }
        candidates.append(target.root)
        var seenPIDs = Set<pid_t>()
        return candidates
            .filter { seenPIDs.insert($0.pid).inserted }
            .filter { processInspector.isRunning($0) }
    }

    /// SIGKILLs the session's owned set: the captured stop target when one
    /// exists, otherwise a fresh capture from the terminal's current PID.
    private func terminateOwnedProcesses(for sessionID: UUID) {
        guard let session = session(withID: sessionID),
              let target = stopTargets[sessionID] ?? freshStopTarget(for: session) else { return }
        let alive = aliveOwnedIdentities(of: target)
        guard !alive.isEmpty else { return }
        HeadlessSessionProcesses.signalAttached(alive, SIGKILL)
    }

    /// User-initiated termination from the Sessions UI: stops the process
    /// like `stopSession` and, unlike a plain stop, closes the session once
    /// its process is gone so the pane returns to the empty state instead of
    /// a dead terminal view. Applies to the orchestrator the same as any
    /// other row; the next launch can create a fresh one if none remains.
    func terminateSession(id: UUID) {
        guard let session = session(withID: id) else { return }
        guard session.activity != .exited else {
            closeSession(id: id)
            return
        }
        closeOnExitIDs.insert(id)
        startingRestorations.removeValue(forKey: id)
        persistRestorationSnapshot()
        stopSession(id: id)
    }

    /// The persistent orchestrator row, if one exists (live or exited).
    func orchestratorSession() -> ConsoleSession? {
        sessions.first(where: { $0.purpose == .orchestrator })
    }

    func children(of parent: ConsoleSession) -> [ConsoleSession] {
        children(of: parent.claudeSessionID)
    }

    private func children(of parentClaudeSessionID: UUID) -> [ConsoleSession] {
        sessions.filter { $0.parentClaudeSessionID == parentClaudeSessionID }
    }

    private func checkChildCapacity(parentClaudeSessionID: UUID?) throws {
        guard let parentClaudeSessionID else { return }
        // Restoration can launch children before their parent row appears.
        let liveChildren = children(of: parentClaudeSessionID).filter { $0.activity != .exited }
        guard liveChildren.count < Self.maxOrchestratorChildren else {
            throw SessionCreationError.orchestratorChildLimitReached(limit: Self.maxOrchestratorChildren)
        }
    }

    /// Best-effort Claude Code version for capability hints.
    func claudeVersionHint() -> String? {
        locator.resolvedClaudeVersion()
    }

    /// Queues Claude Code `/compact` for a live session. Used by the
    /// orchestrator's Compact control in place of Terminate.
    func compactSession(id: UUID) {
        queueSlashCommand("/compact", for: id)
    }

    /// Closes the pending force-stop offer without killing the process.
    func dismissForceStopOffer() {
        awaitingForceStopSessionID = nil
    }

#if DEBUG
    /// UI-test support: injects inert fake sessions (no processes) so tests can
    /// exercise list, switching, stop confirmation, and exited retention.
    func injectUITestPreviewSessions(withOrchestrator: Bool = false) {
        guard sessions.isEmpty else { return }

        func makeView() -> LocalProcessTerminalView {
            let view = ConsoleTerminalView()
            view.configureAppearance()
            return view
        }

        var alpha = ConsoleSession(
            id: UUID(),
            claudeSessionID: UUID(),
            name: "Preview Alpha",
            workingDirectory: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Projects"),
            terminalView: makeView(),
            activity: .idle,
            attention: .none,
            summary: "Refactor complete, all checks green.",
            artifacts: [
                SessionArtifact(kind: .jiraIssue, label: "ENG-101"),
                SessionArtifact(kind: .gitlabMergeRequest, label: "MR !42"),
                SessionArtifact(kind: .jiraIssue, label: "ENG-202"),
            ],
            bridgeStatus: .unknown
        )
        alpha.activity = .working

        var beta = ConsoleSession(
            id: UUID(),
            claudeSessionID: UUID(),
            name: "Preview Beta",
            workingDirectory: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Sandbox"),
            terminalView: makeView(),
            activity: .starting,
            attention: .none,
            summary: nil,
            artifacts: [],
            bridgeStatus: .unknown
        )
        beta.activity = .exited

        if withOrchestrator {
            let orchestrator = ConsoleSession(
                id: UUID(), claudeSessionID: UUID(), name: "Preview Orchestrator",
                workingDirectory: alpha.workingDirectory, terminalView: makeView(),
                activity: .exited, attention: .none, summary: nil, artifacts: [],
                bridgeStatus: .unknown, purpose: .orchestrator
            )
            sessions.append(orchestrator)
            beta.parentClaudeSessionID = orchestrator.claudeSessionID
        }
        sessions.append(contentsOf: [alpha, beta])
        selectedSessionID = alpha.id
    }
#endif

    /// Bounded stop escalation: after the grace period, SIGKILLs whatever is
    /// still alive from the captured stop target and waits a bounded time for
    /// the root to die. Only when even SIGKILL fails is the manual Force Stop
    /// offer raised. A final sweep re-signals survivors so a descendant that
    /// outlived the root cannot be orphaned once the session closes.
    private func scheduleOwnedStopEscalation(id: UUID, target: SessionStopTarget) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.gracefulStopGraceSeconds))
            guard let self else { return }
            let alive = self.aliveOwnedIdentities(of: target)
            if !alive.isEmpty {
                HeadlessSessionProcesses.signalAttached(alive, SIGKILL)
                for _ in 0..<30 {
                    if !self.processInspector.isRunning(target.root) { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            // Liveness decides, not the activity flag: a bridge
            // `sessionEnded` can mark the row exited while the process
            // still hangs, and that process must still be escalatable.
            if self.session(withID: id) != nil,
               self.processInspector.isRunning(target.root) {
                self.awaitingForceStopSessionID = id
            }
            let remaining = self.aliveOwnedIdentities(of: target)
            if !remaining.isEmpty {
                HeadlessSessionProcesses.signalAttached(remaining, SIGKILL)
            }
        }
    }

    /// Removes an exited session (and its retained scrollback) from the list.
    func removeSession(id: UUID) {
        guard let session = session(withID: id), session.activity == .exited else { return }
        closeSession(id: id)
    }

    /// Inserts a session, keeping the orchestrator pinned at the top.
    private func insertSession(_ session: ConsoleSession) {
        if session.purpose == .orchestrator {
            sessions.insert(session, at: 0)
        } else {
            sessions.append(session)
            pinOrchestratorToTop()
        }
        writeSessionsSnapshot()
    }

    private func pinOrchestratorToTop() {
        guard let index = sessions.firstIndex(where: { $0.purpose == .orchestrator }), index != 0 else { return }
        let orchestrator = sessions.remove(at: index)
        sessions.insert(orchestrator, at: 0)
    }

    /// Drops a session and its plumbing entirely. The terminal view, process
    /// handle, and scrollback are released with it. A process that is still
    /// alive is killed first, so removing a row marked exited by a bridge
    /// event cannot orphan its PTY child.
    private func closeSession(id: UUID, preservingRestoration: Bool = false) {
        if !preservingRestoration, let session = session(withID: id) {
            pendingRestorations.removeAll { $0.id == session.claudeSessionID }
            if session.purpose != .blank, session.purpose != .orchestrator,
               session.lastTurnStarted != nil || TranscriptTail.transcriptURL(
                   claudeSessionID: session.claudeSessionID, projectsRoot: TranscriptTail.defaultProjectsRoot
               ) != nil {
                let record = restorationRecord(for: session, processIdentity: nil)
                recentlyClosedSessions.removeAll { $0.id == record.id }
                recentlyClosedSessions.insert(record, at: 0)
                recentlyClosedSessions = Array(recentlyClosedSessions.prefix(10))
            }
        }
        terminateOwnedProcesses(for: id)
        stopTargets.removeValue(forKey: id)
        dropDirectives(for: id, reason: .exited)
        if !preservingRestoration, let session = session(withID: id) {
            watchedConversations.remove(session.claudeSessionID)
            if session.purpose == .orchestrator {
                watchedConversations = []
                recheckDue = nil
            }
        }
        if let brief = childBriefDirectories.removeValue(forKey: id) { try? FileManager.default.removeItem(at: brief) }
        sessions.removeAll(where: { $0.id == id })
        sessionTokens.removeValue(forKey: id)
        pendingSlashCommands.removeValue(forKey: id)
        settlingSessions.remove(id)
        router.forget(sessionID: id)
        closeOnExitIDs.remove(id)
        startingRestorations.removeValue(forKey: id)
        if selectedSessionID == id {
            selectedSessionID = sessions.first?.id
        }
        persistRestorationSnapshot()
        writeSessionsSnapshot()
    }

    func handleProcessTerminated(sessionID: UUID, startExitShell: Bool = true) {
        stopTargets.removeValue(forKey: sessionID)
        pendingSlashCommands.removeValue(forKey: sessionID)
        settlingSessions.remove(sessionID)
        dropDirectives(for: sessionID, reason: .exited)
        if !isTerminating, let record = startingRestorations.removeValue(forKey: sessionID) {
            if !pendingRestorations.contains(where: { $0.id == record.id }) {
                pendingRestorations.append(record)
            }
            restorationMessage = "\(record.name) could not resume. Check its terminal for details, then retry Restore Sessions."
        }
        if closeOnExitIDs.remove(sessionID) != nil {
            notifyLifecycle(sessionID: sessionID, event: .processTerminated)
            closeSession(id: sessionID)
            return
        }
        applyEvent(.processTerminated, to: sessionID)
        writeSessionsSnapshot()
        // A retained pane must never sit as a dead terminal: when the Claude
        // child exits, hand the same terminal view to a login shell so the
        // user gets a command-line prompt. Scrollback is preserved by
        // SwiftTerm; a resumed Claude reports SessionStart through the same
        // bridge. A Blank session's shell IS the session: its exit ends the
        // session, so no replacement shell is started.
        guard startExitShell,
              let session = session(withID: sessionID),
              session.purpose != .blank,
              session.terminalView.process?.running != true else { return }
        launcher.startExitShell(
            workingDirectory: session.workingDirectory.path,
            environment: exitShellEnvironment(for: sessionID),
            terminalView: session.terminalView
        )
    }

    private func exitShellEnvironment(for sessionID: UUID) -> [String: String] {
        let fallback = childEnvironment(bridgeEnvironment: [:])
        guard let token = sessionTokens[sessionID], let socketPath,
              let pluginRoot = assembledPluginRoot, let executable = locator.locate() else {
            return fallback
        }
        let environment = childEnvironment(bridgeEnvironment: [
            "CONSOLE_TERM_BRIDGE_HELPER": Self.helperPath(),
            "CONSOLE_TERM_BRIDGE_SOCKET": socketPath,
            "CONSOLE_TERM_BRIDGE_SESSION_ID": sessionID.uuidString,
            "CONSOLE_TERM_BRIDGE_TOKEN": token,
            "CONSOLE_SESSIONS_SNAPSHOT": sessionsSnapshotPath() ?? "",
            "CONSOLE_MCP_RESULTS_DIR": mcpResultsDirectoryURL()?.path ?? "",
        ])
        do {
            return try SessionExitShellBootstrap.environment(
                environment, root: ephemeralRoot.appendingPathComponent("exit-shell"),
                executable: executable, pluginDirectory: pluginRoot.path
            )
        } catch {
            if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
                sessions[index].bridgeStatus = .unavailable
                sessions[index].instrumentationWarning = SessionCreationError.pluginAssemblyFailed.errorDescription
            }
            return fallback
        }
    }

    /// Stops every running session. Used on actual app termination only —
    /// hiding the window leaves everything running. Sessions marked exited
    /// by a bridge event but still owning a live process are killed too.
    func terminateAll() {
        persistRestorationSnapshot()
        isTerminating = true
        for session in sessions {
            terminateOwnedProcesses(for: session.id)
            if session.activity != .exited {
                // App termination: no exit shell, nothing would ever use it.
                handleProcessTerminated(sessionID: session.id, startExitShell: false)
            }
        }
    }

    // MARK: - Terminal input API

    /// Submits a prompt into the session's PTY using SwiftTerm's main-thread
    /// input API. Multiline prompts use bracketed-paste bytes followed by Return.
    @discardableResult
    func submit(prompt: String, to sessionID: UUID) -> SubmissionResult {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .rejected(.emptyPrompt)
        }
        guard let session = session(withID: sessionID) else {
            return .rejected(.sessionNotFound)
        }
        guard PromptSubmissionEngine.acceptsPrompt(prompt, activity: session.activity) else {
            return .rejected(.sessionNotAcceptingInput)
        }
        let bytes = PromptSubmissionEngine.bytes(for: prompt)
        sendToTerminal(bytes, sessionID: sessionID, terminalView: session.terminalView)
        applyEvent(.promptSubmitted, to: sessionID)
        return .submitted
    }

    private func sendToTerminal(_ bytes: [UInt8], sessionID: UUID, terminalView: LocalProcessTerminalView) {
        #if DEBUG
        debugTerminalSendBytes.append((sessionID, String(decoding: bytes, as: UTF8.self)))
        #endif
        terminalView.send(data: bytes[...])
    }

    // MARK: - Header-menu commands

    /// Shared replacement-and-submit path for the terminal header's menus
    /// (Quick Commands and the color palette): clears the current input line in the
    /// terminal's actual input editor — Ctrl+U/Ctrl+K control bytes, not a
    /// screen erase — then inserts `command` and presses Return. Status is
    /// deliberately untouched; the bridge reports what the session does with
    /// the command. Rejected once the session has exited, including while it
    /// sits at its fallback login shell.
    ///
    /// Clear-line controls, command text, and Return are three spaced writes.
    /// Combining clear-line controls with the paste makes Claude consume Return
    /// to confirm removal of invisible characters instead of submitting.
    /// Claude Code reads a single burst containing the text and the
    /// carriage return as one paste, so the embedded Return is inserted into
    /// the input line instead of submitting it. The queued-command path uses
    /// the same split.
    @discardableResult
    func sendSlashCommand(_ command: String, to sessionID: UUID) -> SubmissionResult {
        guard let session = session(withID: sessionID) else {
            return .rejected(.sessionNotFound)
        }
        guard session.activity != .exited else {
            return .rejected(.sessionNotAcceptingInput)
        }
        sendReplacementCommand(command, to: sessionID)
        return .submitted
    }

    /// Keep clear-line controls out of the paste: Claude otherwise inserts them
    /// as invisible characters and consumes Return to confirm sanitization.
    private func sendReplacementCommand(_ command: String, to sessionID: UUID,
                                        onSubmitted: @escaping () -> Void = {}) {
        guard let session = session(withID: sessionID), session.activity != .exited else { return }
        sendToTerminal(PromptSubmissionEngine.clearDraftBytes, sessionID: sessionID, terminalView: session.terminalView)
        afterQueuedCommandSpacing { [weak self] in
            guard let self, let session = self.session(withID: sessionID), session.activity != .exited else { return }
            self.sendToTerminal(PromptSubmissionEngine.replacementCommandText(command),
                                sessionID: sessionID, terminalView: session.terminalView)
            self.afterQueuedCommandSpacing { [weak self] in
                guard let self, let session = self.session(withID: sessionID), session.activity != .exited else { return }
                self.sendToTerminal(PromptSubmissionEngine.returnBytes,
                                    sessionID: sessionID, terminalView: session.terminalView)
                onSubmitted()
            }
        }
    }

    // MARK: - Session color command

    /// Sends Claude Code's `/color <argument>` slash command through the
    /// shared replacement-and-submit path: the editor's current line is cleared
    /// first, then the command and Return are sent. A local slash command
    /// changes only the prompt bar color, so the session's activity and
    /// attention are deliberately left untouched — submitting a color must
    /// never mark the session Working.
    @discardableResult
    func sendColorCommand(_ argument: String, to sessionID: UUID) -> SubmissionResult {
        sendSlashCommand("/color \(argument)", to: sessionID)
    }

    // MARK: - Session rename command

    /// Sends Claude Code's `/rename <name>` slash command so the session's
    /// own name matches the name the user set on its card. Runs through the
    /// shared replacement-and-submit path; like `/color`, the local command
    /// must not flip activity or attention, and exited sessions reject it.
    @discardableResult
    func sendRenameCommand(_ name: String, to sessionID: UUID) -> SubmissionResult {
        sendSlashCommand("/rename \(name)", to: sessionID)
    }

    #if DEBUG
    /// Test seam: the in-memory bridge token for one session so tests can
    /// craft envelopes the router accepts. Never used at runtime.
    func debugSessionToken(_ sessionID: UUID) -> String? {
        sessionTokens[sessionID]
    }

    /// Test seam: feeds an envelope through the same validated router path as
    /// the socket server without opening a socket.
    func debugReceiveEnvelope(_ envelope: BridgeEnvelope) {
        guard let data = try? envelope.encodedData() else { return }
        router.receive(rawData: data)
    }
    #endif

    // MARK: - Bridge events

    /// Optimistic signal that the user typed into the terminal: clears
    /// permission/question attention without waiting for hook round-trips.
    func noteUserInput(sessionID: UUID) {
        guard session(withID: sessionID) != nil else { return }
        lastUserInputAt[sessionID] = Date()
        let attention = session(withID: sessionID)?.attention
        applyEvent(.userInputObserved, to: sessionID)
        if heldDirectives[sessionID] != nil { scheduleDirectiveRecheck() }
        if attention != session(withID: sessionID)?.attention { writeSessionsSnapshot() }
    }

    fileprivate func handleValidatedEnvelope(sessionID: UUID, envelope: BridgeEnvelope) {
        let becameActive = markActive(sessionID: sessionID)
        // Queued input goes out after this envelope's event is applied, so a
        // queued prompt's Working state is not overwritten by SessionStart.
        if becameActive { settlingSessions.insert(sessionID) }
        defer { if becameActive { flushPendingWhenSettled(sessionID: sessionID) } }

        let event: SessionLifecycleEvent
        switch envelope.kind {
        case .lifecycle:
            switch envelope.lifecycleEvent {
            case .sessionStarted: event = .sessionStarted
            case .promptSubmitted: event = .promptSubmitted
            case .turnCompleted: event = .turnCompleted
            case .turnFailed: event = .turnFailed
            case .idleObserved:
                // Stop does not fire after a user interrupt. An idle prompt
                // while still Working is that missed turn end; otherwise the
                // turn already ended and this must not relay a second time.
                guard session(withID: sessionID)?.activity == .working else { return }
                event = .turnCompleted
            case .sessionEnded: event = .sessionEnded
            case .none: return
            }
        case .attention:
            guard let category = envelope.attentionCategory else { return }
            event = .attentionReported(category, message: envelope.attentionMessage)
        case .artifact:
            guard let kind = envelope.artifactKind, let label = envelope.artifactLabel else { return }
            let url = envelope.artifactURL.flatMap(URL.init(string:))
            event = .artifactLinked(SessionArtifact(kind: kind, label: label, url: url))
        case .completion:
            guard let outcome = envelope.completionOutcome, let summary = envelope.completionSummary else { return }
            event = .completionReported(outcome, summary: summary)
        case .cwd:
            guard let directory = envelope.cwdDirectory else { return }
            event = .cwdChanged(directory)
        case .createSession:
            handleCreateSessionRequest(from: sessionID, envelope: envelope)
            return
        case .closeSession:
            handleCloseSessionRequest(from: sessionID, envelope: envelope)
            return
        case .promptSession:
            handlePromptSessionRequest(from: sessionID, envelope: envelope)
            return
        case .cancelDirective:
            handleCancelDirectiveRequest(from: sessionID, envelope: envelope)
            return
        case .refreshSessions:
            writeSessionsSnapshot()
            writeMCPResult(requestID: envelope.requestID, ok: true)
            return
        case .homeBoard:
            handleHomeBoardRequest(from: sessionID, envelope: envelope)
            return
        case .getPlan, .updatePlan, .watchSession, .recheckIn:
            handleOrchestratorRequest(from: sessionID, envelope: envelope)
            return
        }

        applyEvent(event, to: sessionID)
        handleDirectiveLifecycle(sessionID: sessionID, event: event)
        writeSessionsSnapshot()
    }

    private var watchedSessions: [UUID: UUID] = [:]
    private var scheduledRechecks: [UUID: Task<Void, Never>] = [:]
    /// Durable forms of the two above, keyed by Claude conversation so they
    /// outlive Console session IDs, which change on every restore.
    private var watchedConversations: Set<UUID> = []
    private var recheckDue: Date?
    /// Conversations launched read-only. History records carry no profile, so
    /// this keeps a later resume from handing them full tools.
    private var readOnlyConversations: [UUID] = []
    private var childBriefDirectories: [UUID: URL] = [:]

    private func armRecheck(for requesterID: UUID, due: Date) {
        scheduledRechecks[requesterID]?.cancel()
        scheduledRechecks[requesterID] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, due.timeIntervalSinceNow))) } catch { return }
            guard let self else { return }
            self.scheduledRechecks.removeValue(forKey: requesterID)
            self.recheckDue = nil
            self.persistRestorationSnapshot()
            self.relay("Console relay: scheduled recheck is due. Read the plan and continue ready work within the approval tiers.", to: requesterID)
        }
    }

    /// Decisions the plan is waiting on the user for. Home renders these as
    /// cards; the observer drives the Dock badge and notifications.
    private(set) var openDecisions: [OrchestratorPlan.Decision] = []
    @ObservationIgnored var openDecisionsObserver: (@MainActor (_ added: [OrchestratorPlan.Decision], _ openCount: Int) -> Void)?

    private func refreshOpenDecisions(from plan: OrchestratorPlan?, announce: Bool) {
        let open = (plan ?? (try? loadOrchestratorPlan()))?.decisions.filter { $0.answer == nil } ?? []
        guard open != openDecisions else { return }
        let known = Set(openDecisions.map(\.id))
        openDecisions = open
        openDecisionsObserver?(announce ? open.filter { !known.contains($0.id) } : [], open.count)
    }

    /// Records the user's answer from a Home card and wakes the Orchestrator.
    /// The revision bump makes a plan update the Orchestrator had in flight
    /// fail and reload, so the answer cannot be overwritten.
    func answerDecision(id: Int, option: String) throws {
        guard let url = orchestratorPlanURL else { throw CocoaError(.fileNoSuchFile) }
        var plan = try loadOrchestratorPlan()
        guard let index = plan.decisions.firstIndex(where: { $0.id == id && $0.answer == nil }),
              plan.decisions[index].options.contains(option) else {
            refreshOpenDecisions(from: plan, announce: false)
            throw CocoaError(.fileReadCorruptFile)
        }
        plan.decisions[index].answer = option
        plan.revision += 1
        try plan.json().write(to: url, options: .atomic)
        refreshOpenDecisions(from: plan, announce: false)
        let question = plan.decisions[index].question.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(200)
        wakeOrchestrator("Console relay: the user answered decision \(id) (\(question)) with \"\(option)\" on the Home board. "
            + "It is already saved in the plan and approves exactly that decision. Call get_plan, then act on it. "
            + "If the answer says they did something outside Console (approved, merged, posted), that is a claim: "
            + "check it with get_home_board before marking anything complete.")
    }

    /// The user clicked a decision card instead of one of its buttons: they
    /// want the details and a recommendation before deciding. Returns the
    /// Orchestrator to switch to, if one is live.
    @discardableResult
    func discussWithOrchestrator(decision id: Int) -> UUID? {
        guard let orchestrator = orchestratorSession(), orchestrator.activity != .exited else { return nil }
        guard let decision = openDecisions.first(where: { $0.id == id }) else { return orchestrator.id }
        let question = decision.question.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(200)
        relay("Console relay: the user opened decision \(id) (\(question)) from the Home board and wants to discuss it before deciding. "
            + "Explain the details and current state, say what each option leads to, and give your recommendation. "
            + "Do not act on it or record an answer until they decide.", to: orchestrator.id)
        return orchestrator.id
    }

    /// Queues a note for the live Orchestrator, if there is one.
    @discardableResult
    func wakeOrchestrator(_ note: String) -> Bool {
        guard let orchestrator = orchestratorSession(), orchestrator.activity != .exited else { return false }
        relay(note, to: orchestrator.id)
        return true
    }

    /// Reattaches saved watches and the pending recheck to live sessions.
    private func restoreWakeUps() {
        refreshOpenDecisions(from: nil, announce: false)
        guard let orchestrator = orchestratorSession(), orchestrator.activity != .exited else { return }
        for session in sessions where session.activity != .exited && session.id != orchestrator.id
            && watchedConversations.contains(session.claudeSessionID) {
            watchedSessions[session.id] = orchestrator.id
        }
        if let recheckDue, scheduledRechecks[orchestrator.id] == nil {
            armRecheck(for: orchestrator.id, due: recheckDue)
        }
    }

    private var bridgeDirectory: URL? {
        socketPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
    }

    private var orchestratorPlanURL: URL? {
        (restorationStore?.url.deletingLastPathComponent() ?? bridgeDirectory)?
            .appendingPathComponent("orchestrator-plan.json")
    }

    func loadOrchestratorPlan() throws -> OrchestratorPlan {
        guard let url = orchestratorPlanURL else { return .init() }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .init()
        }
        let plan = try JSONDecoder().decode(OrchestratorPlan.self, from: data)
        guard plan.isValid else { throw CocoaError(.fileReadCorruptFile) }
        return plan
    }

    private func handleOrchestratorRequest(from requesterID: UUID, envelope: BridgeEnvelope) {
        let requestID = envelope.requestID
        guard let requester = session(withID: requesterID),
              requester.purpose == .orchestrator, requester.activity != .exited else {
            writeMCPResult(requestID: requestID, ok: false, error: "only the live orchestrator may use this tool")
            return
        }
        switch envelope.kind {
        case .getPlan, .updatePlan:
            do {
                var plan: OrchestratorPlan
                do {
                    plan = try loadOrchestratorPlan()
                } catch {
                    guard let url = orchestratorPlanURL else { throw error }
                    let aside = url.deletingLastPathComponent().appendingPathComponent("orchestrator-plan.unreadable.json")
                    try? FileManager.default.removeItem(at: aside)
                    try FileManager.default.moveItem(at: url, to: aside)
                    plan = .init()
                }
                if envelope.kind == .updatePlan {
                    guard let id = envelope.planUpdateID, let bridgeDirectory, let url = orchestratorPlanURL else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    let staged = bridgeDirectory.appendingPathComponent("plan-update-\(id).json")
                    defer { try? FileManager.default.removeItem(at: staged) }
                    let values = try staged.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true,
                          let size = values.fileSize, (1...65536).contains(size) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    var updated = try JSONDecoder().decode(OrchestratorPlan.self, from: Data(contentsOf: staged))
                    guard updated.isValid else { throw CocoaError(.fileReadCorruptFile) }
                    guard updated.revision == plan.revision else {
                        writeMCPResult(requestID: requestID, ok: false, error: "plan revision changed; reload with get_plan")
                        return
                    }
                    updated.revision += 1
                    let data = try updated.json()
                    guard data.count <= 65536 else { throw CocoaError(.fileWriteOutOfSpace) }
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                    plan = updated
                }
                refreshOpenDecisions(from: plan, announce: envelope.kind == .updatePlan)
                // The Orchestrator just sent the plan; echoing it back only costs tokens.
                let output = envelope.kind == .updatePlan
                    ? "{\"ok\":true,\"revision\":\(plan.revision)}"
                    : String(decoding: try plan.json(), as: UTF8.self)
                writeMCPResult(requestID: requestID, ok: true, output: output)
            } catch {
                writeMCPResult(requestID: requestID, ok: false, error: "could not read or update plan: \(error.localizedDescription)")
            }
        case .watchSession:
            guard let raw = envelope.targetSessionID, let id = UUID(uuidString: raw),
                  let target = session(withID: id), target.purpose != .orchestrator, target.purpose != .blank,
                  target.activity != .exited else {
                writeMCPResult(requestID: requestID, ok: false, error: "watch requires a live Claude peer")
                return
            }
            watchedSessions[id] = requesterID
            watchedConversations.insert(target.claudeSessionID)
            persistRestorationSnapshot()
            writeMCPResult(requestID: requestID, ok: true, sessionID: id, status: "watching")
        case .recheckIn:
            guard let minutes = envelope.recheckMinutes else { return }
            let due = Date().addingTimeInterval(minutes * 60)
            recheckDue = due
            armRecheck(for: requesterID, due: due)
            persistRestorationSnapshot()
            writeMCPResult(requestID: requestID, ok: true, status: "scheduled")
        default:
            break
        }
    }

    /// Console MCP create: only the orchestrator may request new sessions.
    private func handleCreateSessionRequest(from requesterID: UUID, envelope: BridgeEnvelope) {
        let requestID = envelope.requestID
        guard let requester = session(withID: requesterID),
              requester.purpose == .orchestrator,
              requester.activity != .exited else {
            writeMCPResult(requestID: requestID, ok: false, error: "only the orchestrator may create sessions")
            return
        }
        guard let purposeRaw = envelope.createPurpose,
              let purpose = SessionPurpose(rawValue: purposeRaw),
              purpose != .orchestrator,
              SessionPurpose.userSelectableCases.contains(purpose) else {
            writeMCPResult(requestID: requestID, ok: false, error: "invalid or disallowed purpose")
            return
        }
        var prompt = envelope.createInitialPrompt ?? ""
        guard purpose != .blank || (prompt.isEmpty && envelope.createBriefID == nil) else {
            writeMCPResult(requestID: requestID, ok: false, error: "blank sessions cannot take an initial_prompt")
            return
        }
        let name = envelope.createName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (name?.isEmpty == false) ? name! : purpose.defaultName(source: nil)
        // Agent is opt-in only. Do not invent `agent-review` for purpose=review —
        // that agent is often absent and would fail the launch.
        let workingDirectory: URL
        if let path = envelope.createCWD {
            guard let validated = validatedChildDirectory(path) else {
                writeMCPResult(requestID: requestID, ok: false, error: "cwd must be an available directory inside a configured workspace")
                return
            }
            workingDirectory = validated
        } else {
            workingDirectory = requester.workingDirectory
        }
        var briefDirectory: URL?
        if let briefID = envelope.createBriefID, let socketPath {
            let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
            let brief = directory.appendingPathComponent("child-brief-\(briefID).md")
            guard briefID == requestID,
                  let values = try? brief.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, (1...262144).contains(size) else {
                writeMCPResult(requestID: requestID, ok: false, error: "staged child brief unavailable")
                return
            }
            // Expose only the child brief to the restricted process, not the socket's siblings.
            let context = directory.appendingPathComponent("child-context-\(briefID)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: context, withIntermediateDirectories: false)
                let childBrief = context.appendingPathComponent("brief.md")
                try FileManager.default.moveItem(at: brief, to: childBrief)
                briefDirectory = context
                prompt = "Read the task brief at \"\(childBrief.path)\" and carry out its instructions."
            } catch {
                try? FileManager.default.removeItem(at: context)
                writeMCPResult(requestID: requestID, ok: false, error: "could not prepare child brief")
                return
            }
        }
        let profile: SessionToolProfile = envelope.createToolProfile == "readOnlyPrep"
            ? .readOnlyPrep(contextDirectory: briefDirectory ?? workingDirectory) : .standard
        do {
            let createdID = try createSession(request: SessionCreationRequest(
                purpose: purpose,
                name: displayName,
                workingDirectory: workingDirectory,
                agent: envelope.createAgent,
                model: envelope.createModel,
                toolProfile: profile,
                revealsSession: false,
                parentClaudeSessionID: requester.claudeSessionID
            ))
            if let briefDirectory { childBriefDirectories[createdID] = briefDirectory }
            if purpose != .blank, let created = session(withID: createdID) {
                queueSlashCommand("/rename \(created.name)", for: createdID)
            }
            if !prompt.isEmpty {
                queuePrompt(prompt, for: createdID) { [weak self] in
                    guard let self else { return }
                    self.directiveOrigins[createdID] = requesterID
                    self.awaitingAcceptance[createdID] = Date()
                    self.scheduleDirectiveRecheck()
                    self.writeSessionsSnapshot()
                }
            }
            writeSessionsSnapshot()
            writeMCPResult(requestID: requestID, ok: true, sessionID: createdID)
        } catch {
            if let briefDirectory { try? FileManager.default.removeItem(at: briefDirectory) }
            writeMCPResult(requestID: requestID, ok: false, error: error.localizedDescription)
        }
    }

    @ObservationIgnored var childWorkspaceRoots: (@MainActor () -> [URL])?

    private func validatedChildDirectory(_ path: String) -> URL? {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        let directory = URL(fileURLWithPath: CheckoutPath.canonical(URL(fileURLWithPath: expanded)), isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              childWorkspaceRoots?().contains(where: { root in
                  let components = URL(fileURLWithPath: CheckoutPath.canonical(root)).pathComponents
                  return directory.pathComponents.starts(with: components)
              }) == true else { return nil }
        return directory
    }

    /// Console MCP close: only the orchestrator may close peers; never itself.
    private func handleCloseSessionRequest(from requesterID: UUID, envelope: BridgeEnvelope) {
        let requestID = envelope.requestID
        guard let requester = session(withID: requesterID),
              requester.purpose == .orchestrator else {
            writeMCPResult(requestID: requestID, ok: false, error: "only the orchestrator may close sessions")
            return
        }
        guard let targetRaw = envelope.targetSessionID,
              let targetID = UUID(uuidString: targetRaw),
              let target = session(withID: targetID) else {
            writeMCPResult(requestID: requestID, ok: false, error: "session not found")
            return
        }
        guard target.purpose != .orchestrator else {
            writeMCPResult(requestID: requestID, ok: false, error: "refused: cannot close the orchestrator session")
            return
        }
        closedByOrchestrator.insert(targetID)
        terminateSession(id: targetID)
        writeSessionsSnapshot()
        writeMCPResult(requestID: requestID, ok: true, sessionID: targetID)
    }

    /// Console MCP cancel: drop directives still waiting for a session.
    private func handleCancelDirectiveRequest(from requesterID: UUID, envelope: BridgeEnvelope) {
        let requestID = envelope.requestID
        guard session(withID: requesterID)?.purpose == .orchestrator else {
            writeMCPResult(requestID: requestID, ok: false, error: "only the orchestrator may cancel directives")
            return
        }
        guard let targetRaw = envelope.targetSessionID,
              let targetID = UUID(uuidString: targetRaw),
              session(withID: targetID) != nil else {
            writeMCPResult(requestID: requestID, ok: false, error: "session not found")
            return
        }
        let cancelled = cancelHeldDirectives(for: targetID, from: requesterID)
        writeSessionsSnapshot()
        writeMCPResult(requestID: requestID, ok: true, sessionID: targetID,
                       status: cancelled == 0
                           ? "nothing held: directives already typed cannot be cancelled"
                           : "cancelled \(cancelled) held directive(s)")
    }

    /// Supplies the current Home board text; set by the launch coordinator,
    /// which owns the Home data sources.
    @ObservationIgnored var homeBoardBriefProvider: (@MainActor () -> String)?
    /// Re-reads live source state before the brief is built. Must finish
    /// inside the bridge's result wait.
    @ObservationIgnored var homeBoardRefresh: (@MainActor () async -> Void)?

    /// Console MCP home board: the scan brief rebuilt from current data.
    private func handleHomeBoardRequest(from requesterID: UUID, envelope: BridgeEnvelope) {
        let requestID = envelope.requestID
        guard session(withID: requesterID)?.purpose == .orchestrator else {
            writeMCPResult(requestID: requestID, ok: false, error: "only the orchestrator may read the Home board")
            return
        }
        guard let homeBoardBriefProvider else {
            writeMCPResult(requestID: requestID, ok: false, error: "Home board unavailable")
            return
        }
        guard let homeBoardRefresh else {
            writeMCPResult(requestID: requestID, ok: true, output: homeBoardBriefProvider())
            return
        }
        Task { [weak self] in
            await homeBoardRefresh()
            self?.writeMCPResult(requestID: requestID, ok: true, output: homeBoardBriefProvider())
        }
    }

    /// Console MCP prompt: queue a directive into another visible session.
    private func handlePromptSessionRequest(from requesterID: UUID, envelope: BridgeEnvelope) {
        let requestID = envelope.requestID
        guard let requester = session(withID: requesterID),
              requester.purpose == .orchestrator else {
            writeMCPResult(requestID: requestID, ok: false, error: "only the orchestrator may prompt sessions")
            return
        }
        guard let targetRaw = envelope.targetSessionID,
              let targetID = UUID(uuidString: targetRaw),
              let target = session(withID: targetID) else {
            writeMCPResult(requestID: requestID, ok: false, error: "session not found")
            return
        }
        guard target.purpose != .orchestrator else {
            writeMCPResult(requestID: requestID, ok: false, error: "refused: cannot prompt the orchestrator session")
            return
        }
        guard target.purpose != .blank else {
            writeMCPResult(requestID: requestID, ok: false, error: "blank sessions cannot be prompted")
            return
        }
        guard target.activity != .exited else {
            writeMCPResult(requestID: requestID, ok: false, error: "session has exited")
            return
        }
        guard let prompt = envelope.promptText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty else {
            writeMCPResult(requestID: requestID, ok: false, error: "prompt is required")
            return
        }
        let delivery = deliverDirective(prompt, to: targetID, relayTo: requesterID)
        writeSessionsSnapshot()
        writeMCPResult(requestID: requestID, ok: true, sessionID: targetID, status: delivery.resultStatus)
    }

    /// Returns true when this envelope is the session's first validated one.
    private func markActive(sessionID: UUID) -> Bool {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
              sessions[index].bridgeStatus != .active else { return false }
        sessions[index].bridgeStatus = .active
        return true
    }

    // MARK: - Orchestrator directives

    /// Directives (and relay notes) held until the target can take input
    /// without answering a permission/question dialog, interrupting a turn,
    /// or wiping a draft the user is typing.
    private var heldDirectives: [UUID: [HeldDirective]] = [:]
    /// Text being typed into a target right now; blocks a double send while
    /// the spaced clear/text/Return writes are in flight.
    private var directivesInFlight: [UUID: String] = [:]
    /// Target → orchestrator waiting to hear that target's outcome.
    private var directiveOrigins: [UUID: UUID] = [:]
    /// Targets whose directive was typed but whose Claude has not yet
    /// reported the prompt as submitted.
    private var awaitingAcceptance: [UUID: Date] = [:]
    /// Last keystroke the user typed into each terminal.
    private var lastUserInputAt: [UUID: Date] = [:]
    private var directiveRecheckScheduled = false
    @ObservationIgnored var transcriptReply: (UUID, Date?) -> String? = {
        TranscriptTail.currentTurnReply(claudeSessionID: $0, since: $1)
    }
    private var pendingRelays: [UUID: PendingRelay] = [:]
    /// Sessions the Orchestrator closed itself. It already knows they are
    /// gone, so their exit is not relayed back to it.
    private var closedByOrchestrator: Set<UUID> = []

    private enum RelayOutcome: String {
        case attention = "changed attention"
        case endedTurn = "ended its turn"
        case failed
        case finished
        case blocked = "reported blocked"
        case review = "reported ready for review"
        case exited = "exited"
    }

    private struct PendingRelay {
        let target: ConsoleSession
        let recipient: UUID
        let outcome: RelayOutcome
        let directive: Bool
        let task: Task<Void, Never>
    }

    /// Typing within this window (longer while the terminal has focus) means
    /// the user may have a draft that a delivery would erase.
    static let typingQuietSeconds: TimeInterval = 5
    static let focusedTypingQuietSeconds: TimeInterval = 15
    /// A typed directive Claude never reports as submitted is abandoned.
    static let acceptanceTimeoutSeconds: TimeInterval = 20
    static let directiveRecheckSeconds: TimeInterval = 2
    /// Lets a completion report that trails the turn-end event land first.
    static let relaySettleSeconds: TimeInterval = 1

    enum DirectiveDelivery: Equatable {
        case sent, held, duplicate

        var resultStatus: String {
            switch self {
            case .sent: return "sent"
            case .held: return "held until the target is idle"
            case .duplicate: return "duplicate: the same directive is already pending for this session"
            }
        }
    }

    private struct HeldDirective {
        let text: String
        let relayTo: UUID?
        var relaySource: UUID?
        var relayOutcome: RelayOutcome?
        var render: (() -> String)?
    }

    /// True when typed input lands in Claude's prompt as a new user turn.
    static func canTakeDirective(_ session: ConsoleSession) -> Bool {
        session.bridgeStatus == .active
            && session.activity == .idle
            && (session.attention == .none || session.attention == .unreadCompletion)
    }

    /// True while the user may be composing in that terminal.
    func userMayBeTyping(in sessionID: UUID, now: Date = Date()) -> Bool {
        guard let last = lastUserInputAt[sessionID] else { return false }
        let window = viewingFocusDetector(sessionID) ? Self.focusedTypingQuietSeconds : Self.typingQuietSeconds
        return now.timeIntervalSince(last) < window
    }

    /// Number of directives waiting for, or being typed into, a session.
    func pendingDirectiveCount(for sessionID: UUID) -> Int {
        (heldDirectives[sessionID]?.count ?? 0) + (directivesInFlight[sessionID] == nil ? 0 : 1)
    }

    /// Queues `text` for `targetID`, sending at once when it is safe. When
    /// `relayTo` is set, that session hears the target's outcome when its
    /// directed turn ends. Identical pending text for the same target is
    /// dropped so a retried tool call cannot send twice.
    @discardableResult
    func deliverDirective(_ text: String, to targetID: UUID, relayTo: UUID?) -> DirectiveDelivery {
        deliverDirective(HeldDirective(text: text, relayTo: relayTo), to: targetID)
    }

    @discardableResult
    private func deliverDirective(_ directive: HeldDirective, to targetID: UUID) -> DirectiveDelivery {
        if let source = directive.relaySource, let outcome = directive.relayOutcome {
            let progress: Set<RelayOutcome> = [.attention, .endedTurn]
            if let index = heldDirectives[targetID]?.firstIndex(where: { held in
                guard held.relaySource == source, let heldOutcome = held.relayOutcome else { return false }
                return heldOutcome == outcome || (progress.contains(heldOutcome) && outcome != .attention)
            }) {
                heldDirectives[targetID]?[index] = directive
            } else {
                heldDirectives[targetID, default: []].append(directive)
            }
        } else {
            if directivesInFlight[targetID] == directive.text
                || heldDirectives[targetID]?.contains(where: { $0.text == directive.text }) == true {
                return .duplicate
            }
            heldDirectives[targetID, default: []].append(directive)
        }
        if deliverHeldDirectives(for: targetID) { return .sent }
        scheduleDirectiveRecheck()
        return .held
    }

    @discardableResult
    private func deliverHeldDirectives(for targetID: UUID) -> Bool {
        guard directivesInFlight[targetID] == nil,
              awaitingAcceptance[targetID] == nil,
              !settlingSessions.contains(targetID),
              let session = session(withID: targetID),
              Self.canTakeDirective(session),
              !userMayBeTyping(in: targetID),
              var held = heldDirectives[targetID], !held.isEmpty else { return false }
        let next = held.removeFirst()
        heldDirectives[targetID] = held.isEmpty ? nil : held
        if let origin = next.relayTo {
            directiveOrigins[targetID] = origin
        }
        let text = next.render?() ?? next.text
        directivesInFlight[targetID] = text
        let expectsRelay = next.relayTo != nil
        queuePrompt(text, for: targetID) { [weak self] in
            guard let self else { return }
            self.directivesInFlight.removeValue(forKey: targetID)
            if expectsRelay {
                self.awaitingAcceptance[targetID] = Date()
                self.scheduleDirectiveRecheck()
            }
            self.writeSessionsSnapshot()
        }
        return true
    }

    /// Re-checks held directives and acceptance deadlines on a short timer,
    /// so deliveries also resume after state changes that send no bridge
    /// event (a dismissed card, a pause in typing).
    private func scheduleDirectiveRecheck() {
        guard !directiveRecheckScheduled else { return }
        directiveRecheckScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.directiveRecheckSeconds) { [weak self] in
            guard let self else { return }
            self.directiveRecheckScheduled = false
            self.recheckDirectives()
        }
    }

    func recheckDirectives(now: Date = Date()) {
        for (targetID, typedAt) in awaitingAcceptance
        where now.timeIntervalSince(typedAt) >= Self.acceptanceTimeoutSeconds {
            awaitingAcceptance.removeValue(forKey: targetID)
            if let origin = directiveOrigins.removeValue(forKey: targetID),
               let target = session(withID: targetID) {
                relay(Self.relayNote(target: target, outcome: "did not accept"), to: origin)
            }
        }
        for targetID in Array(heldDirectives.keys) {
            deliverHeldDirectives(for: targetID)
        }
        if !heldDirectives.isEmpty || !awaitingAcceptance.isEmpty {
            scheduleDirectiveRecheck()
        }
    }

    /// A turn boundary leaves the origin intact. A report resolves the
    /// directive even when Claude stays live for follow-up work.
    private func handleDirectiveLifecycle(sessionID: UUID, event: SessionLifecycleEvent) {
        switch event {
        case .promptSubmitted:
            awaitingAcceptance.removeValue(forKey: sessionID)
            if directiveOrigins[sessionID] != nil,
               let pid = session(withID: sessionID)?.terminalView.process?.shellPid, pid > 1 {
                turnBaselineProcesses[sessionID] = OwnedProcessTree.descendantIDs(of: pid)
            }
        case .turnCompleted, .turnFailed:
            awaitingAcceptance.removeValue(forKey: sessionID)
            if let session = session(withID: sessionID), session.completionOutcome == nil {
                let failed = event == .turnFailed || Self.currentTurnFailed(session)
                scheduleRelay(for: sessionID, outcome: failed ? .failed : .endedTurn)
                if !failed, pendingRelays[sessionID] == nil {
                    Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(Self.relaySettleSeconds)) } catch { return }
                        guard let self, let current = self.session(withID: sessionID), current.activity == .idle,
                              current.lastTurnEnd == session.lastTurnEnd else { return }
                        self.recordTranscriptFailure(for: sessionID, reply: self.transcriptReply(
                            current.claudeSessionID, current.lastTurnStarted
                        ))
                    }
                }
            }
        case .completionReported(let report, _):
            let outcome: RelayOutcome = switch report {
            case .completed: .finished
            case .blocked: .blocked
            case .needsReview: .review
            }
            scheduleRelay(for: sessionID, outcome: outcome)
            directiveOrigins.removeValue(forKey: sessionID)
        case .attentionReported(.blocked, _):
            scheduleRelay(for: sessionID, outcome: .blocked)
            directiveOrigins.removeValue(forKey: sessionID)
        case .sessionEnded:
            pendingSlashCommands.removeValue(forKey: sessionID)
            settlingSessions.remove(sessionID)
            dropDirectives(for: sessionID, reason: .exited)
        default:
            break
        }
        deliverHeldDirectives(for: sessionID)
    }

    private func scheduleRelay(for sessionID: UUID, outcome: RelayOutcome) {
        // Any relay still settling (the closed session's last turn) is kept.
        if outcome == .exited && closedByOrchestrator.contains(sessionID) { return }
        let previous = pendingRelays[sessionID]
        let origin = directiveOrigins[sessionID]
        guard let recipient = origin ?? watchedSessions[sessionID] ?? previous?.recipient,
              let target = session(withID: sessionID) else { return }
        // A Stop or attention echo can follow a report. Keep the more
        // informative result during the debounce window.
        if let previous {
            if outcome == .attention && previous.outcome != .attention { return }
            if outcome == .endedTurn && previous.outcome != .attention && previous.outcome != .endedTurn { return }
            if outcome == .exited && [.finished, .blocked, .review, .failed].contains(previous.outcome) { return }
            previous.task.cancel()
        }
        let task = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(Self.relaySettleSeconds)) } catch { return }
            self?.enqueueSettledRelay(for: sessionID)
        }
        pendingRelays[sessionID] = PendingRelay(target: target, recipient: recipient, outcome: outcome,
                                                directive: origin != nil || previous?.directive == true, task: task)
    }

    private func enqueueSettledRelay(for sessionID: UUID) {
        guard let pending = pendingRelays.removeValue(forKey: sessionID),
              session(withID: pending.recipient)?.activity != .exited,
              session(withID: pending.recipient) != nil else { return }
        // Detect a failure as soon as the transcript settles, including while
        // the Orchestrator is busy. Read again immediately before delivery.
        _ = relayContent(pending)
        // A turn that ended and left nothing running has nothing more to
        // report, so later turns in that session are no longer the directive's.
        if [.endedTurn, .failed].contains(pending.outcome), directiveOrigins[sessionID] == pending.recipient,
           let current = session(withID: sessionID), current.activity != .working,
           current.lastTurnStarted == pending.target.lastTurnStarted, hasLiveWork(current) == false {
            directiveOrigins.removeValue(forKey: sessionID)
            turnBaselineProcesses.removeValue(forKey: sessionID)
        }
        let next = HeldDirective(text: "", relayTo: nil, relaySource: sessionID, relayOutcome: pending.outcome,
                                 render: { [weak self] in self?.relayContent(pending) ?? "" })
        deliverDirective(next, to: pending.recipient)
        writeSessionsSnapshot()
    }

    /// Processes the directed turn started that are still alive, such as a
    /// background build. Nil when Console cannot tell.
    private var turnBaselineProcesses: [UUID: Set<pid_t>] = [:]
    @ObservationIgnored var liveWorkProbe: ((ConsoleSession) -> Bool?)?

    private func hasLiveWork(_ session: ConsoleSession) -> Bool? {
        if let liveWorkProbe { return liveWorkProbe(session) }
        guard let pid = session.terminalView.process?.shellPid, pid > 1,
              let baseline = turnBaselineProcesses[session.id] else { return nil }
        return !OwnedProcessTree.descendantIDs(of: pid).subtracting(baseline).isEmpty
    }

    private func relayContent(_ pending: PendingRelay) -> String {
        let current = session(withID: pending.target.id)
        let sameTurn = current?.lastTurnStarted == pending.target.lastTurnStarted
        let target = sameTurn ? current ?? pending.target : pending.target
        var outcome = pending.outcome
        var reply: String?
        if sameTurn || current == nil {
            reply = transcriptReply(target.claudeSessionID, target.lastTurnStarted)
        }
        if [.endedTurn, .failed, .exited].contains(outcome),
           (reply?.hasPrefix("API Error") == true || Self.currentTurnFailed(target)) {
            outcome = .failed
            if sameTurn { recordTranscriptFailure(for: target.id, reply: reply) }
        }
        return Self.relayNote(target: target, outcome: outcome.rawValue, lastReply: reply,
                              directed: pending.directive)
    }

    private static func currentTurnFailed(_ session: ConsoleSession) -> Bool {
        session.lastTurnFailed && (session.lastTurnEnd ?? .distantPast) >= (session.lastTurnStarted ?? .distantPast)
    }

    private func recordTranscriptFailure(for id: UUID, reply: String?) {
        guard reply?.hasPrefix("API Error") == true,
              let session = session(withID: id), session.activity == .idle,
              !Self.currentTurnFailed(session) else { return }
        applyEvent(.turnFailed, to: id)
        writeSessionsSnapshot()
    }

    /// Removes held directives for `targetID` that `requesterID` sent.
    /// Relay notes held for the orchestrator itself are not touched.
    @discardableResult
    func cancelHeldDirectives(for targetID: UUID, from requesterID: UUID) -> Int {
        guard let held = heldDirectives[targetID] else { return 0 }
        let kept = held.filter { $0.relayTo != requesterID }
        heldDirectives[targetID] = kept.isEmpty ? nil : kept
        return held.count - kept.count
    }

    private func dropDirectives(for sessionID: UUID, reason: RelayOutcome) {
        scheduleRelay(for: sessionID, outcome: reason)
        heldDirectives.removeValue(forKey: sessionID)
        directivesInFlight.removeValue(forKey: sessionID)
        awaitingAcceptance.removeValue(forKey: sessionID)
        lastUserInputAt.removeValue(forKey: sessionID)
        turnBaselineProcesses.removeValue(forKey: sessionID)
        directiveOrigins.removeValue(forKey: sessionID)
        directiveOrigins = directiveOrigins.filter { $0.value != sessionID }
        watchedSessions.removeValue(forKey: sessionID)
        watchedSessions = watchedSessions.filter { $0.value != sessionID }
        scheduledRechecks.removeValue(forKey: sessionID)?.cancel()
    }

    private func relay(_ note: String, to orchestratorID: UUID) {
        guard let orchestrator = session(withID: orchestratorID),
              orchestrator.activity != .exited else { return }
        deliverDirective(note, to: orchestratorID, relayTo: nil)
    }

    /// Long enough for a child's full result, so the Orchestrator does not
    /// need a second read to see it.
    static let relayReplyLimit = 2_500

    static func relayNote(target: ConsoleSession, outcome: String, lastReply: String? = nil,
                          directed: Bool = true) -> String {
        func oneLine(_ text: String, limit: Int) -> String {
            String(text.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(limit))
        }
        let suffix = directed && ["finished", "failed", "did not accept"].contains(outcome) ? " your directive" : ""
        var note = "Console relay: session \"\(target.name)\" (id=\(target.id.uuidString)) \(outcome)\(suffix)."
        if ["finished", "reported blocked", "reported ready for review"].contains(outcome),
           let report = target.completionOutcome, let summary = target.summary {
            note += " Report (\(report.rawValue)): \(oneLine(summary, limit: 400))"
        }
        if let reply = lastReply?.trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty {
            note += " Last reply: \(oneLine(reply, limit: Self.relayReplyLimit))"
        } else if target.completionOutcome == nil, let summary = target.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            note += " Summary: \(oneLine(summary, limit: 400))"
        }
        if target.toolProfile != .standard, outcome == RelayOutcome.endedTurn.rawValue {
            note += " This session is read-only and cannot call report_completion; its last reply is its result."
        }
        if target.attention != .none && target.attention != .unreadCompletion {
            note += " It now needs the user: \(target.attention.rawValue)"
            if let ask = target.attentionMessage { note += " (\(oneLine(ask, limit: 200)))" }
            note += "."
        }
        note += " Update the plan and continue ready work within the approval tiers. Batch outward-facing decisions for the user."
        return note
    }

    // MARK: - Queued slash commands

    /// Slash commands waiting for a session's Claude Code to start reading
    /// input. Contextual launches (review rename + default color) enqueue
    /// right after creation; sending earlier would type into the pre-Claude
    /// login shell. Keyed by session, flushed in queue order.
    private var pendingSlashCommands: [UUID: [QueuedInput]] = [:]

    /// One queued terminal submission. A prompt is Console-authored text sent
    /// after any queued slash commands; `onSubmitted` runs once its Return is
    /// written.
    private enum QueuedInput {
        case command(String)
        case prompt(String, onSubmitted: (@MainActor () -> Void)?)

        var text: String {
            switch self {
            case .command(let command): return command
            case .prompt(let prompt, _): return prompt
            }
        }
    }

    /// Spacing between clear-line controls, pasted text, Return, and between
    /// consecutive queued commands. Claude Code reads a burst containing the
    /// text and one or more carriage returns as a single paste, so the embedded
    /// returns never submit. Tests shorten this to zero and take the
    /// synchronous path.
    var queuedCommandSpacing: TimeInterval = 0.2

    /// Queues a slash command for a session whose Claude Code is not yet
    /// live; flushed in order when the bridge first reports active. A
    /// already-live session sends immediately; exited sessions drop it.
    func queueSlashCommand(_ command: String, for sessionID: UUID) {
        guard let session = session(withID: sessionID), session.activity != .exited else { return }
        if session.bridgeStatus == .active, !settlingSessions.contains(sessionID) {
            sendSlashCommand(command, to: sessionID)
            return
        }
        pendingSlashCommands[sessionID, default: []].append(.command(command))
    }

    /// Queues a single-line, Console-authored prompt behind any queued slash
    /// commands and submits it once the bridge reports the session live. It is
    /// typed like a queued command (text, then a separately written Return)
    /// and marks the session Working. Exited sessions drop it.
    func queuePrompt(
        _ prompt: String,
        for sessionID: UUID,
        collapsingNewlines: Bool = true,
        onSubmitted: (@MainActor () -> Void)? = nil
    ) {
        let normalized = prompt
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let line = (collapsingNewlines
            ? normalized.components(separatedBy: .newlines).joined(separator: " ")
            : normalized)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, let session = session(withID: sessionID), session.activity != .exited else { return }
        if session.bridgeStatus == .active, !settlingSessions.contains(sessionID) {
            submitQueuedCommands([.prompt(line, onSubmitted: onSubmitted)], index: 0, sessionID: sessionID)
            return
        }
        pendingSlashCommands[sessionID, default: []].append(.prompt(line, onSubmitted: onSubmitted))
    }

    /// Blocks directives while the terminal draws its startup screen and while
    /// queued startup input is being submitted.
    private var settlingSessions: Set<UUID> = []
    static let startupQuietSeconds: TimeInterval = 0.8
    static let startupSettleLimitSeconds: TimeInterval = 8
    private static let startupPollSeconds: TimeInterval = 0.2

    private func flushPendingWhenSettled(sessionID: UUID) {
        // Without a running child (tests, fake launchers) nothing draws, so
        // there is nothing to wait for.
        guard queuedCommandSpacing > 0,
              let terminal = session(withID: sessionID)?.terminalView,
              terminal.process?.running == true else {
            flushPendingSlashCommands(sessionID: sessionID)
            return
        }
        pollStartupSettled(sessionID: sessionID, activatedAt: Date())
    }

    private func pollStartupSettled(sessionID: UUID, activatedAt: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.startupPollSeconds) { [weak self] in
            guard let self, let session = self.session(withID: sessionID), session.activity != .exited else {
                self?.settlingSessions.remove(sessionID)
                return
            }
            let now = Date()
            let lastOutput = (session.terminalView as? ConsoleTerminalView)?.lastOutputAt ?? activatedAt
            let quiet = now.timeIntervalSince(max(lastOutput, activatedAt)) >= Self.startupQuietSeconds
            let expired = now.timeIntervalSince(activatedAt) >= Self.startupSettleLimitSeconds
            guard quiet || expired else {
                self.pollStartupSettled(sessionID: sessionID, activatedAt: activatedAt)
                return
            }
            self.flushPendingSlashCommands(sessionID: sessionID)
        }
    }

    private func flushPendingSlashCommands(sessionID: UUID) {
        guard let commands = pendingSlashCommands.removeValue(forKey: sessionID), !commands.isEmpty else {
            settlingSessions.remove(sessionID)
            deliverHeldDirectives(for: sessionID)
            return
        }
        submitQueuedCommands(commands, index: 0, sessionID: sessionID) { [weak self] in
            self?.flushPendingSlashCommands(sessionID: sessionID)
        }
    }

    /// Submits queued commands one at a time. Clear-line controls, pasted text,
    /// and each command's carriage return are separate writes, spaced apart,
    /// so Claude Code submits each command individually instead of reading
    /// them as one pasted line.
    private func submitQueuedCommands(_ commands: [QueuedInput], index: Int, sessionID: UUID,
                                      onFinished: (() -> Void)? = nil) {
        guard let session = session(withID: sessionID),
              session.activity != .exited else { return }
        guard index < commands.count else {
            onFinished?()
            return
        }
        sendReplacementCommand(commands[index].text, to: sessionID) { [weak self] in
            guard let self else { return }
            if case .prompt(_, let onSubmitted) = commands[index] {
                self.applyEvent(.promptSubmitted, to: sessionID)
                onSubmitted?()
            }
            self.afterQueuedCommandSpacing { [weak self] in
                self?.submitQueuedCommands(commands, index: index + 1, sessionID: sessionID, onFinished: onFinished)
            }
        }
    }

    /// Runs `block` after `queuedCommandSpacing`; with zero spacing it runs
    /// synchronously so tests can assert the exact write sequence.
    private func afterQueuedCommandSpacing(_ block: @escaping () -> Void) {
        if queuedCommandSpacing > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + queuedCommandSpacing, execute: block)
        } else {
            block()
        }
    }

    /// The literal "user is looking at this session" check behind
    /// `viewingFocusDetector`: the app is active, the session is selected,
    /// and keyboard focus sits inside its terminal view.
    private func isViewingFocus(sessionID: UUID) -> Bool {
        guard sessionID == selectedSessionID, NSApp.isActive else { return false }
        guard let window = NSApp.keyWindow,
              let firstResponder = window.firstResponder as? NSView,
              let terminalView = session(withID: sessionID)?.terminalView else { return false }
        return firstResponder.isDescendant(of: terminalView)
    }

    private func applyEvent(_ event: SessionLifecycleEvent, to sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        if case .sessionStarted = event {
            startingRestorations.removeValue(forKey: sessionID)
        }
        if case .sessionEnded = event {
            startingRestorations.removeValue(forKey: sessionID)
        }

        if case .artifactLinked(let artifact) = event {
            appendArtifact(artifact, toSessionAt: index)
            rememberAssociation(for: sessions[index])
            notifyLifecycle(sessionID: sessionID, event: event)
            return
        }

        let previous = sessions[index]
        let now = Date()
        switch event {
        case .sessionStarted:
            sessions[index].lastTurnStarted = nil
            sessions[index].lastTurnEnd = nil
            sessions[index].lastTurnFailed = false
            sessions[index].completionOutcome = nil
        case .promptSubmitted:
            sessions[index].lastTurnStarted = now
            sessions[index].completionOutcome = nil
        case .turnCompleted, .turnFailed:
            sessions[index].lastTurnEnd = now
            sessions[index].lastTurnFailed = event == .turnFailed || Self.currentTurnFailed(previous)
        case .completionReported(let outcome, _):
            sessions[index].completionOutcome = outcome
        default:
            break
        }
        let viewing = viewingFocusDetector(sessionID)
        var state = SessionLifecycleState(
            activity: sessions[index].activity,
            attention: sessions[index].attention,
            summary: sessions[index].summary,
            workingDirectoryPath: sessions[index].workingDirectory.path
        )
        if event != .turnCompleted || !Self.currentTurnFailed(previous) {
            state.apply(event)
        }
        if viewing,
           state.attention == .unreadCompletion,
           sessions[index].attention != .unreadCompletion {
            // The user is literally watching this session finish, so a
            // needs-attention notification would be redundant: the completion
            // is never surfaced as unread. Blocking attention (permission,
            // question, blocked, needs review) still applies — it marks an
            // outstanding input request, not a completion ping.
            state.attention = .none
        }
        sessions[index].activity = state.activity
        sessions[index].attention = state.attention
        sessions[index].summary = state.summary
        if case .attentionReported(_, let message) = event {
            let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines)
            sessions[index].attentionMessage = (trimmed?.isEmpty == false) ? trimmed : nil
        } else if state.attention == .none || state.attention == .unreadCompletion {
            sessions[index].attentionMessage = nil
        }
        if let path = state.workingDirectoryPath {
            sessions[index].workingDirectory = URL(fileURLWithPath: path)
        }

        // An unread completion is a display state, not a request for anyone.
        func request(_ attention: SessionAttention) -> SessionAttention {
            attention == .unreadCompletion ? .none : attention
        }
        let attentionChanged = request(previous.attention) != request(sessions[index].attention)
            || previous.attentionMessage != sessions[index].attentionMessage
        if previous.activity != sessions[index].activity
            || request(previous.attention) != request(sessions[index].attention) {
            sessions[index].stateSince = now
        }
        if attentionChanged, watchedSessions[sessionID] != nil,
           ![SessionLifecycleEvent.turnCompleted, .turnFailed, .sessionEnded, .processTerminated].contains(event) {
            scheduleRelay(for: sessionID, outcome: .attention)
        }
        if event == .sessionStarted { restoreWakeUps() }
        notifyLifecycle(sessionID: sessionID, event: event)
        persistRestorationSnapshot()
    }

    // MARK: - Restoration

    #if DEBUG
    func injectUITestHeadlessPreview() {
        headlessPreviewMode = true
        let record = SessionRestorationRecord(claudeSessionID: UUID(), name: "Headless Preview",
                                              workingDirectory: URL(fileURLWithPath: "/tmp/console-preview"), purpose: .general)
        let process = SessionProcessSnapshot(identity: .init(pid: 999999, startedSeconds: 1, startedMicroseconds: 0),
                                             parentPID: 1, claudeSessionID: record.id, isConsoleOwned: true)
        headlessSessions = [.init(record: record, process: process)]
    }
    #endif

    func refreshHeadlessSessions() async {
        #if DEBUG
        if headlessPreviewMode { return }
        #endif
        guard !isScanningProcesses, !isTerminating else { return }
        isScanningProcesses = true
        defer { isScanningProcesses = false }
        do {
            let processes = try await processSnapshot()
            guard !isTerminating else { return }
            updateHeadlessSessions(processes)
        } catch {
            headlessMessage = "Could not inspect leftover sessions: \(error.localizedDescription)"
        }
    }

    private func processSnapshot() async throws -> [SessionProcessSnapshot] {
        let inspector = processInspector
        return try await Task.detached(priority: .utility) { try inspector.snapshot() }.value
    }

    private func updateHeadlessSessions(_ processes: [SessionProcessSnapshot]) {
        let liveIDs = Set(sessions.filter { $0.activity != .exited }.map(\.claudeSessionID))
        headlessSessions = processes.compactMap { process in
            guard process.parentPID == 1,
                  let record = pendingRestorations.first(where: {
                      $0.processIdentity == process.identity
                          || (process.isConsoleOwned && $0.id == process.claudeSessionID)
                  }), !liveIDs.contains(record.id) else { return nil }
            return HeadlessSession(record: record, process: process)
        }.sorted { $0.id.pid < $1.id.pid }
    }

    private func process(_ process: SessionProcessSnapshot, matches record: SessionRestorationRecord) -> Bool {
        process.identity == record.processIdentity || process.claudeSessionID == record.id
    }

    /// Used by history and notification resumption before starting another writer.
    func checkConversationAvailable(_ record: SessionRestorationRecord) async throws {
        guard !isRestoringSessions, headlessActionID == nil, !isTerminating else { throw POSIXError(.EBUSY) }
        let running = try await processSnapshot()
        guard !running.contains(where: { process($0, matches: record) }) else { throw POSIXError(.EBUSY) }
    }

    func linkAuthoredMR(_ item: AuthoredMRAttention, sessionID: UUID) throws {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { throw CocoaError(.fileNoSuchFile) }
        // A review conversation can also be explicitly chosen for authoring,
        // but its other reviewed MRs are not evidence of authored work.
        var artifacts = sessions[index].purpose == .review ? [] : sessions[index].artifacts
        artifacts.append(.init(kind: .gitlabMergeRequest, label: "!\(item.iid)", url: item.url))
        if let key = item.jiraIssueKey.flatMap({ JiraSourceContext.parseKey(from: $0) }) {
            artifacts.append(.init(kind: .jiraIssue, label: key))
        }
        let session = sessions[index]
        try associations.remember(record: .init(claudeSessionID: session.claudeSessionID,
            name: session.name, workingDirectory: session.workingDirectory, purpose: session.purpose ?? .general),
            artifacts: artifacts, authoredMR: item.url)
        refreshWorkArtifactProjections()
    }

    /// Attaches an existing GitLab merge request to a session so its header
    /// badge and the review hand-off point at it. The URL is validated as a
    /// merge request; a merge request already attached is left untouched.
    func connectMergeRequest(sessionID: UUID, url: URL) throws {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else {
            throw MergeRequestConnector.ConnectionError.sessionMissing
        }
        guard let identity = MergeRequestConnector.mergeRequestIdentity(url),
              let info = GitLabSourceContext.parseMergeRequest(fromURL: url) else {
            throw MergeRequestConnector.ConnectionError.invalidURL
        }
        let alreadyConnected = sessions[index].artifacts.contains { artifact in
            guard artifact.kind == .gitlabMergeRequest, let url = artifact.url else { return false }
            return MergeRequestConnector.mergeRequestIdentity(url) == identity
        }
        guard !alreadyConnected else { return }

        var artifacts = sessions[index].artifacts
        artifacts.append(.init(kind: .gitlabMergeRequest, label: "MR !\(info.iid)", url: url))
        let session = sessions[index]
        try associations.remember(record: .init(claudeSessionID: session.claudeSessionID,
            name: session.name, workingDirectory: session.workingDirectory, purpose: session.purpose ?? .general),
            artifacts: artifacts)
        refreshWorkArtifactProjections()
    }

    /// Attaches a Jira story URL to a session so the header can open that
    /// issue. The URL must identify one story; a story already attached is
    /// left untouched.
    func connectJiraIssue(sessionID: UUID, url: URL) throws {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else {
            throw JiraIssueConnector.ConnectionError.sessionMissing
        }
        guard let identity = WorkArtifact.identity(kind: .jiraIssue, url: url),
              let key = JiraSourceContext.parseIssueKey(fromURL: url) else {
            throw JiraIssueConnector.ConnectionError.invalidURL
        }
        let alreadyConnected = sessions[index].artifacts.contains { artifact in
            guard artifact.kind == .jiraIssue, let existing = artifact.url else { return false }
            return WorkArtifact.identity(kind: .jiraIssue, url: existing) == identity
        }
        guard !alreadyConnected else { return }

        var artifacts = sessions[index].artifacts
        artifacts.append(.init(kind: .jiraIssue, label: key, url: url))
        let session = sessions[index]
        try associations.remember(record: .init(claudeSessionID: session.claudeSessionID,
            name: session.name, workingDirectory: session.workingDirectory, purpose: session.purpose ?? .general),
            artifacts: artifacts)
        refreshWorkArtifactProjections()
    }

    private func rememberAssociation(for session: ConsoleSession) {
        guard session.purpose != .blank else { return }
        do {
            try associations.remember(record: .init(claudeSessionID: session.claudeSessionID,
                name: session.name, workingDirectory: session.workingDirectory, purpose: session.purpose ?? .general),
                artifacts: session.artifacts)
            refreshWorkArtifactProjections()
            associationPersistenceError = nil
        } catch {
            associationPersistenceError = "Session work links could not be saved: \(error.localizedDescription)"
        }
    }

    private func refreshWorkArtifactProjections() {
        for index in sessions.indices where sessions[index].purpose != .blank {
            sessions[index].artifacts = associations.artifacts(for: sessions[index].claudeSessionID)
        }
    }

    /// macOS cannot transfer a crashed forkpty owner's master to a new process.
    /// Recovery stops that child before resuming the conversation with a new PTY
    /// and newly authenticated bridge. Never run two writers for one conversation.
    func recoverHeadlessSession(_ headless: HeadlessSession, reattach: Bool) async {
        guard headlessActionID == nil, !isRestoringSessions, !isTerminating else { return }
        headlessActionID = headless.id
        headlessMessage = nil
        defer { headlessActionID = nil }
        do {
            let current = try await processSnapshot()
            updateHeadlessSessions(current)
            guard headlessSessions.contains(where: { $0.id == headless.id }) else {
                headlessMessage = "That process is no longer a headless Console session."
                return
            }
            if reattach {
                try checkChildCapacity(parentClaudeSessionID: headless.record.parentClaudeSessionID)
                guard locator.locate() != nil else { throw SessionCreationError.claudeNotFound }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: headless.record.workingDirectory.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { throw CocoaError(.fileNoSuchFile) }
            }
            try processInspector.signal(SIGTERM, to: headless.id)
            for _ in 0..<30 {
                if !processInspector.isRunning(headless.id) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            if processInspector.isRunning(headless.id) {
                try processInspector.signal(SIGKILL, to: headless.id)
                for _ in 0..<20 {
                    if !processInspector.isRunning(headless.id) { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            guard !processInspector.isRunning(headless.id) else { throw POSIXError(.EBUSY) }
            let remaining = try await processSnapshot()
            updateHeadlessSessions(remaining)
            guard !isTerminating, !Task.isCancelled else { return }
            if reattach {
                guard !remaining.contains(where: { process($0, matches: headless.record) }),
                      !sessions.contains(where: { $0.claudeSessionID == headless.record.id && $0.activity != .exited }) else {
                    headlessMessage = "Another process still uses this conversation. Recover or stop it first."
                    return
                }
                let record = headless.record
                for session in sessions.filter({ $0.claudeSessionID == record.id && $0.activity == .exited }) {
                    closeSession(id: session.id, preservingRestoration: true)
                }
                _ = try createSession(request: .init(purpose: record.purpose, name: record.name,
                                                     workingDirectory: record.workingDirectory), resuming: record)
                focusSelectedTerminal()
            } else if !remaining.contains(where: { process($0, matches: headless.record) }) {
                pendingRestorations.removeAll { $0.id == headless.record.id }
                persistRestorationSnapshot()
            }
        } catch {
            headlessMessage = "\(headless.record.name): \(error.localizedDescription)"
                + (reattach ? " The saved conversation is retained; use Restore Sessions to retry if the process has stopped." : "")
            await refreshHeadlessSessions()
        }
    }

    func restoreSessions() async {
        guard canRestoreSessions else { return }
        isRestoringSessions = true
        restorationMessage = nil
        let selection = savedSnapshot.selectedClaudeSessionID
        let records = pendingRestorations
        let restorationOrder = savedSnapshot.sessions.map(\.id)
        var failures: [String] = []
        defer {
            isRestoringSessions = false
            persistRestorationSnapshot()
        }
        let running: [SessionProcessSnapshot]
        do {
            running = try await processSnapshot()
            updateHeadlessSessions(running)
        } catch {
            restorationMessage = "Could not check for running Claude sessions. Restore was cancelled: \(error.localizedDescription)"
            return
        }
        for record in records {
            await Task.yield()
            guard !isTerminating, !Task.isCancelled else { return }
            // Retrying a failed resume replaces its exited pane, never a live session.
            for session in sessions.filter({ $0.claudeSessionID == record.id && $0.activity == .exited }) {
                closeSession(id: session.id, preservingRestoration: true)
            }
            if sessions.contains(where: { $0.claudeSessionID == record.id }) {
                pendingRestorations.removeAll { $0.id == record.id }
                continue
            }
            guard !running.contains(where: { process($0, matches: record) }) else {
                failures.append("\(record.name): Claude is still running. Use its headless session card, or return to its owning terminal.")
                continue
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: record.workingDirectory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                failures.append("\(record.name): folder unavailable (\(record.workingDirectory.path)).")
                continue
            }
            do {
                _ = try createSession(request: .init(purpose: record.purpose, name: record.name,
                                                     workingDirectory: record.workingDirectory), resuming: record)
            } catch {
                failures.append("\(record.name): \(error.localizedDescription)")
            }
        }
        // A previously failed early entry must regain its position on retry.
        let restoredIDs = Set(restorationOrder)
        let restored = sessions.filter { restoredIDs.contains($0.claudeSessionID) }
        sessions = sessions.filter { !restoredIDs.contains($0.claudeSessionID) }
            + restorationOrder.compactMap { id in restored.first { $0.claudeSessionID == id } }
        pinOrchestratorToTop()
        writeSessionsSnapshot()
        if let selected = sessions.first(where: { $0.claudeSessionID == selection }) {
            selectedSessionID = selected.id
        }
        if !failures.isEmpty { restorationMessage = failures.joined(separator: "\n") }
    }

    /// Path of the sessions snapshot beside the bridge socket, if available.
    private func sessionsSnapshotPath() -> String? {
        guard let socketPath else { return nil }
        let directory = (socketPath as NSString).deletingLastPathComponent
        return URL(fileURLWithPath: directory).appendingPathComponent("sessions.json").path
    }

    private static let snapshotSummaryLimit = 200
    private static let snapshotArtifactLimit = 5

    private static func currentGitBranch(in directory: URL) -> String? {
        func readSmallFile(_ url: URL) -> String? {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 4096) else { return nil }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var folder = directory.standardizedFileURL
        while true {
            let dotGit = folder.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                let gitDirectory: URL
                if isDirectory.boolValue {
                    gitDirectory = dotGit
                } else {
                    guard let pointer = readSmallFile(dotGit), pointer.hasPrefix("gitdir: ") else { return nil }
                    let path = String(pointer.dropFirst("gitdir: ".count))
                    gitDirectory = URL(fileURLWithPath: path, isDirectory: true, relativeTo: folder)
                }
                guard let head = readSmallFile(gitDirectory.appendingPathComponent("HEAD")) else { return nil }
                return head.hasPrefix("ref: refs/heads/") ? String(head.dropFirst("ref: refs/heads/".count)) : nil
            }
            let parent = folder.deletingLastPathComponent()
            guard !parent.path.isEmpty, parent.path.count < folder.path.count else { return nil }
            folder = parent
        }
    }

    /// JSON snapshot of live Console sessions for the Console MCP
    /// `list_console_sessions` tool. Written beside the bridge socket.
    private func writeSessionsSnapshot() {
        guard let path = sessionsSnapshotPath() else { return }
        let orchestrator = orchestratorSession()
        let childIDs = Set(orchestrator.map { children(of: $0).map(\.id) } ?? [])
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var processRoots: [pid_t: Set<pid_t>]?
        let payload: [[String: Any]] = sessions.map { session in
            let pid = session.terminalView.process?.shellPid ?? 0
            if pid > 1, processRoots == nil { processRoots = OwnedProcessTree.childrenByParent() }
            let processes = OwnedProcessTree.descendantIDs(of: pid, childrenByParent: processRoots ?? [:])
            let names = processes.compactMap(OwnedProcessTree.processName).filter { $0 != "ConsoleTermBridge" }
            let attention = session.attention == .unreadCompletion && session.completionOutcome == nil
                ? .none : session.attention
            var row: [String: Any] = [
                "id": session.id.uuidString,
                "name": session.name,
                "activity": session.activity.rawValue,
                "attention": session.attention.rawValue,
                "bridge_status": session.bridgeStatus.rawValue,
                "state": displayedSessionState(activity: session.activity, attention: attention).rawValue,
                "tool_profile": session.toolProfile == .standard ? "full" : "readOnlyPrep",
                "model": session.model ?? "default",
                "cwd": session.workingDirectory.path,
                "state_since": formatter.string(from: session.stateSince),
                "state_age_seconds": max(0, Int(now.timeIntervalSince(session.stateSince))),
                "live_child_process_count": names.count,
            ]
            if let branch = Self.currentGitBranch(in: session.workingDirectory) { row["git_branch"] = branch }
            if let end = session.lastTurnEnd {
                row["last_turn_end"] = formatter.string(from: end)
                row["last_turn_outcome"] = session.lastTurnFailed ? "failed" : "ended"
            }
            if let outcome = session.completionOutcome { row["completion_outcome"] = outcome.rawValue }
            if !names.isEmpty { row["live_child_processes"] = Set(names).sorted() }

            if let purpose = session.purpose {
                row["purpose"] = purpose.rawValue
            }
            row["claude_session_id"] = session.claudeSessionID.uuidString
            if let orchestrator, childIDs.contains(session.id) {
                row["parent_id"] = orchestrator.id.uuidString
            }
            if let ask = session.attentionMessage {
                row["attention_message"] = String(ask.prefix(Self.snapshotSummaryLimit))
            }
            if let summary = session.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !summary.isEmpty {
                row["summary"] = String(summary.prefix(Self.snapshotSummaryLimit))
            }
            let artifacts: [[String: Any]] = session.artifacts.prefix(Self.snapshotArtifactLimit).map { artifact in
                var entry: [String: Any] = [
                    "kind": artifact.kind.rawValue,
                    "label": artifact.label,
                ]
                if let url = artifact.url {
                    entry["url"] = url.absoluteString
                }
                return entry
            }
            row["artifacts"] = artifacts
            let pending = pendingDirectiveCount(for: session.id)
            if pending > 0 { row["pending_directives"] = pending }
            if directiveOrigins[session.id] != nil { row["awaiting_directive_outcome"] = true }
            return row
        }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return
        }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Writes the orchestrator scan brief beside the bridge socket so the run
    /// prompt can be one typed line that points at it. A multi-line prompt
    /// reaches Claude as pasted content, which it treats as untrusted data.
    func writeOrchestratorBrief(_ brief: String) -> URL? {
        guard let directory = orchestratorPlanURL?.deletingLastPathComponent() else { return nil }
        let url = directory.appendingPathComponent("orchestrator-brief.md")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try brief.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    /// Directory for MCP tool result files (`mcp-results/<request_id>.json`).
    private func mcpResultsDirectoryURL() -> URL? {
        guard let socketPath else { return nil }
        let directory = (socketPath as NSString).deletingLastPathComponent
        let url = URL(fileURLWithPath: directory).appendingPathComponent("mcp-results", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeMCPResult(requestID: String?, ok: Bool, sessionID: UUID? = nil, error: String? = nil,
                                status: String? = nil, output: String? = nil) {
        guard let requestID, !requestID.isEmpty, let dir = mcpResultsDirectoryURL() else { return }
        var payload: [String: Any] = ["ok": ok]
        if let output { payload["output"] = output }
        if let status { payload["status"] = status }
        if let sessionID { payload["session_id"] = sessionID.uuidString }
        if let error { payload["error"] = error }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return
        }
        try? data.write(to: dir.appendingPathComponent("\(requestID).json"), options: .atomic)
    }

    private func restorationRecord(for session: ConsoleSession, processIdentity: SessionProcessIdentity?) -> SessionRestorationRecord {
        .init(claudeSessionID: session.claudeSessionID, name: session.name,
              workingDirectory: session.workingDirectory, purpose: session.purpose ?? .general,
              processIdentity: processIdentity, parentClaudeSessionID: session.parentClaudeSessionID,
              model: session.model, readOnly: session.toolProfile == .standard ? nil : true)
    }

    private func persistRestorationSnapshot() {
        guard !isTerminating, !restorationLoadFailed, let restorationStore else { return }
        var records = pendingRestorations
        // Sessions being terminated stay in the snapshot until their exit is
        // confirmed: dropping them here would discard recovery metadata while
        // the process is still alive and the termination can still fail.
        for session in sessions where session.activity != .exited {
            rememberAssociation(for: session)
            let record = restorationRecord(
                for: session, processIdentity: HeadlessSessionProcesses.identity(for: session.terminalView.process?.shellPid ?? 0)
            )
            records.removeAll { $0.id == record.id }
            records.append(record)
        }
        // Retain the original order even when only some entries have been restored.
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let oldIDs = Set(savedSnapshot.sessions.map(\.id))
        records = savedSnapshot.sessions.compactMap { byID[$0.id] } + records.filter { !oldIDs.contains($0.id) }
        let selected = selectedSession?.claudeSessionID
        let pendingSelection = savedSnapshot.selectedClaudeSessionID.flatMap { id in
            pendingRestorations.contains(where: { $0.id == id }) ? id : nil
        }
        let snapshot = SessionRestorationSnapshot(sessions: records,
            selectedClaudeSessionID: isRestoringSessions ? savedSnapshot.selectedClaudeSessionID : pendingSelection ?? selected,
            recentlyClosed: recentlyClosedSessions.isEmpty ? nil : recentlyClosedSessions,
            watchedConversations: watchedConversations.isEmpty ? nil : watchedConversations.sorted { $0.uuidString < $1.uuidString },
            recheckDue: recheckDue,
            readOnlyConversations: readOnlyConversations.isEmpty ? nil : readOnlyConversations)
        guard snapshot != savedSnapshot else { return }
        do {
            try restorationStore.save(snapshot)
            savedSnapshot = snapshot
            restorationPersistenceError = nil
        } catch {
            restorationPersistenceError = "Sessions could not be saved: \(error.localizedDescription)"
        }
    }

    private func appendArtifact(_ artifact: SessionArtifact, toSessionAt index: Int) {
        var artifacts = sessions[index].artifacts
        if artifacts.contains(where: { $0.kind == artifact.kind && $0.label == artifact.label && $0.url == artifact.url }) {
            return
        }
        artifacts.append(artifact)
        if artifacts.count > 20 {
            artifacts.removeFirst(artifacts.count - 20)
        }
        sessions[index].artifacts = artifacts
    }
}

private extension [String: String] {
    /// Drops entries whose value is empty so unset paths never leak as "".
    func filterEnvironmentValues() -> [String: String] {
        filter { !$0.value.isEmpty }
    }
}
