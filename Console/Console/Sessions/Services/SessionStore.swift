import AppKit
import Foundation
import SwiftTerm

enum SessionCreationError: LocalizedError, Equatable {
    case claudeNotFound
    case pluginAssemblyFailed
    case sessionLaunchFailed

    var errorDescription: String? {
        switch self {
        case .claudeNotFound:
            return "Claude Code was not found on this Mac. Install Claude Code or pick its executable in Settings → Claude Executable."
        case .pluginAssemblyFailed:
            return "Console could not prepare the local bridge for this session. The terminal will still work, but session status is unavailable."
        case .sessionLaunchFailed:
            return "Console could not start Claude for this session. Check the executable path in Settings → Claude Executable."
        }
    }
}

/// App-owned observable store for all Console Claude sessions.
///
/// Sessions are memory-only: nothing here persists across launches.
@MainActor
@Observable
final class SessionStore {
    private(set) var sessions: [ConsoleSession] = []
    private(set) var selectedSessionID: UUID?
    private(set) var awaitingForceStopSessionID: UUID?
    /// Sessions the user terminated; closed (removed) as soon as their
    /// process exits instead of lingering as dead terminals.
    @ObservationIgnored private var closeOnExitIDs: Set<UUID> = []

    @ObservationIgnored let locator: ClaudeExecutableLocator
    @ObservationIgnored private var launcher: any SessionProcessLaunching
    @ObservationIgnored private let pluginAssembler: any ConsoleClaudePluginAssembling

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

    static let gracefulStopGraceSeconds: UInt64 = 3

    init(
        launcher: any SessionProcessLaunching,
        locator: ClaudeExecutableLocator,
        pluginAssembler: any ConsoleClaudePluginAssembling = ConsoleClaudePluginAssembler()
    ) {
        self.launcher = launcher
        self.locator = locator
        self.pluginAssembler = pluginAssembler
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
    }

    convenience init(launcher: any SessionProcessLaunching) {
        self.init(launcher: launcher, locator: ClaudeExecutableLocator())
    }

    convenience init() {
        self.init(launcher: ClaudeSessionLauncher())
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

    /// Live sessions whose canonical working directory matches `canonicalPath`.
    /// Exited rows are ignored. Unknown/legacy purposes are treated as editing.
    func liveEditingSessions(occupyingCanonicalPath canonicalPath: String) -> [ConsoleSession] {
        sessions.filter { session in
            guard session.activity != .exited else { return false }
            let occupies = session.purpose?.occupiesCheckoutForEditing ?? true
            guard occupies else { return false }
            return CheckoutPath.canonical(session.workingDirectory) == canonicalPath
        }
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
        guard let claudePath = locator.locate() else {
            throw SessionCreationError.claudeNotFound
        }

        startBridgeIfNeeded()

        let consoleID = UUID()
        let claudeID = UUID()
        let displayName = Self.uniquedName(request.name.trimmingCharacters(in: .whitespacesAndNewlines), existingNames: activeNames)

        let terminalView = launcher.makeTerminalView()

        let coordinator = SessionTerminalCoordinator(sessionID: consoleID, store: self)
        terminalView.processDelegate = coordinator

        // Plugin/bridge preparation is optional. A failure of either the
        // plugin assembly or the socket/server still launches the resolved
        // Claude executable without unusable plugin arguments.
        let pluginRoot = materializePluginRoot()
        let token: String?
        let arguments: [String]
        let environment: [String: String]
        let bridgeStatus: BridgeStatus
        let instrumentationWarning: String?

        if let pluginRoot, isBridgeInstrumented, socketPath != nil {
            let sessionToken = Self.generateToken()
            token = sessionToken
            arguments = Self.launchArguments(
                claudeSessionID: claudeID,
                pluginDirectory: pluginRoot.path
            )
            environment = childEnvironment(
                bridgeEnvironment: [
                    "CONSOLE_TERM_BRIDGE_HELPER": Self.helperPath(),
                    "CONSOLE_TERM_BRIDGE_SOCKET": socketPath ?? "",
                    "CONSOLE_TERM_BRIDGE_SESSION_ID": consoleID.uuidString,
                    "CONSOLE_TERM_BRIDGE_TOKEN": sessionToken,
                ]
            )
            // Unknown until a validated envelope arrives; never start as active.
            bridgeStatus = .unknown
            instrumentationWarning = nil
        } else {
            token = nil
            arguments = Self.launchArguments(
                claudeSessionID: claudeID,
                pluginDirectory: nil
            )
            environment = childEnvironment(bridgeEnvironment: [:])
            bridgeStatus = .unavailable
            instrumentationWarning = SessionCreationError.pluginAssemblyFailed.errorDescription
        }

        let session = ConsoleSession(
            id: consoleID,
            claudeSessionID: claudeID,
            name: displayName,
            workingDirectory: request.workingDirectory,
            terminalView: terminalView,
            activity: .starting,
            attention: .none,
            summary: nil,
            artifacts: Self.initialArtifacts(for: request.source),
            bridgeStatus: bridgeStatus,
            purpose: request.purpose,
            instrumentationWarning: instrumentationWarning
        )

        let previousSelection = selectedSessionID
        sessions.append(session)
        if let token {
            sessionTokens[consoleID] = token
        }
        select(sessionID: consoleID)

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
            selectedSessionID = previousSelection
            throw error
        }
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

    /// Exact launch arguments: Claude session identity with bypassed
    /// permission prompts, and when a plugin directory is available the
    /// bundled plugin plus preapproval of only the three Console MCP tool
    /// names. The local Console display name is omitted — it must not reach
    /// the child CLI. Uninstrumented launches pass identity only so a missing
    /// plugin cannot block Claude.
    static func launchArguments(claudeSessionID: UUID, pluginDirectory: String?) -> [String] {
        var arguments = [
            "--session-id", claudeSessionID.uuidString,
            "--dangerously-skip-permissions",
        ]
        if let pluginDirectory {
            arguments += ["--plugin-dir", pluginDirectory]
            arguments += ["--allowedTools"] + ConsoleClaudePluginAssembler.allowedToolNames
        }
        return arguments
    }

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
    }

    /// Drops the selection so the Sessions destination shows its empty pane.
    /// Used by the ⌃0 / out-of-range session hotkeys.
    func clearSelection() {
        selectedSessionID = nil
    }

    /// Graceful stop (SIGTERM). The UI's Terminate flow (`terminateSession`)
    /// confirms first for Working / Needs Approval / Needs Input sessions and
    /// calls this afterwards; plain stops retain the exited session row.
    func stopSession(id: UUID) {
        guard let session = session(withID: id), session.activity != .exited else { return }
        awaitingForceStopSessionID = nil
        let pid = session.terminalView.process?.shellPid ?? 0
        guard pid > 0 else {
            handleProcessTerminated(sessionID: id)
            return
        }
        kill(pid, SIGTERM)
        scheduleForceStopOffer(id: id, pid: pid)
    }

    /// Force stop (SIGKILL), offered only when graceful termination did not
    /// complete within the grace period. Liveness, not the activity flag,
    /// decides: a session marked exited by a bridge event can still own a
    /// live process.
    func forceStop(id: UUID) {
        awaitingForceStopSessionID = nil
        guard let session = session(withID: id) else { return }
        let pid = session.terminalView.process?.shellPid ?? 0
        guard pid > 0 else {
            handleProcessTerminated(sessionID: id)
            return
        }
        // A process that no longer exists needs nothing; zombies included.
        guard kill(pid, 0) == 0 else { return }
        kill(pid, SIGKILL)
    }

    /// User-initiated termination from the Sessions UI: stops the process
    /// like `stopSession` and, unlike a plain stop, closes the session once
    /// its process is gone so the pane returns to the empty state instead of
    /// a dead terminal view.
    func terminateSession(id: UUID) {
        guard let session = session(withID: id) else { return }
        guard session.activity != .exited else {
            closeSession(id: id)
            return
        }
        closeOnExitIDs.insert(id)
        stopSession(id: id)
    }

    /// Closes the pending force-stop offer without killing the process.
    func dismissForceStopOffer() {
        awaitingForceStopSessionID = nil
    }

#if DEBUG
    /// UI-test support: injects inert fake sessions (no processes) so tests can
    /// exercise list, switching, stop confirmation, and exited retention.
    func injectUITestPreviewSessions() {
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

        sessions.append(contentsOf: [alpha, beta])
        selectedSessionID = alpha.id
    }
#endif

    private func scheduleForceStopOffer(id: UUID, pid: pid_t) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.gracefulStopGraceSeconds))
            guard let self else { return }
            // Liveness decides, not the activity flag: a bridge
            // `sessionEnded` can mark the row exited while the process
            // still hangs, and that process must still be escalatable.
            guard self.session(withID: id) != nil, kill(pid, 0) == 0 else { return }
            self.awaitingForceStopSessionID = id
        }
    }

    /// Removes an exited session (and its retained scrollback) from the list.
    func removeSession(id: UUID) {
        guard let session = session(withID: id), session.activity == .exited else { return }
        closeSession(id: id)
    }

    /// Drops a session and its plumbing entirely. The terminal view, process
    /// handle, and scrollback are released with it. A process that is still
    /// alive is killed first, so removing a row marked exited by a bridge
    /// event cannot orphan its PTY child.
    private func closeSession(id: UUID) {
        if let session = session(withID: id),
           let pid = session.terminalView.process?.shellPid,
           pid > 0, kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
        }
        sessions.removeAll(where: { $0.id == id })
        sessionTokens.removeValue(forKey: id)
        router.forget(sessionID: id)
        closeOnExitIDs.remove(id)
        if selectedSessionID == id {
            selectedSessionID = sessions.first?.id
        }
    }

    func handleProcessTerminated(sessionID: UUID, startExitShell: Bool = true) {
        if closeOnExitIDs.remove(sessionID) != nil {
            notifyLifecycle(sessionID: sessionID, event: .processTerminated)
            closeSession(id: sessionID)
            return
        }
        applyEvent(.processTerminated, to: sessionID)
        // A retained pane must never sit as a dead terminal: when the Claude
        // child exits, hand the same terminal view to a login shell so the
        // user gets a command-line prompt. Scrollback is preserved by
        // SwiftTerm; the session stays Exited until the user closes it.
        guard startExitShell,
              let session = session(withID: sessionID),
              session.terminalView.process?.running != true else { return }
        launcher.startExitShell(
            workingDirectory: session.workingDirectory.path,
            environment: childEnvironment(bridgeEnvironment: [:]),
            terminalView: session.terminalView
        )
    }

    /// Stops every running session. Used on actual app termination only —
    /// hiding the window leaves everything running. Sessions marked exited
    /// by a bridge event but still owning a live process are killed too.
    func terminateAll() {
        for session in sessions {
            let pid = session.terminalView.process?.shellPid ?? 0
            if pid > 0, kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
            if session.activity != .exited {
                // App termination: no exit shell, nothing would ever use it.
                handleProcessTerminated(sessionID: session.id, startExitShell: false)
            }
        }
    }

    // MARK: - Terminal input API (CONSOLE_TERM_COMM.md §7)

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
        applyEvent(.userInputObserved, to: sessionID)
    }

    fileprivate func handleValidatedEnvelope(sessionID: UUID, envelope: BridgeEnvelope) {
        markActive(sessionID: sessionID)

        let event: SessionLifecycleEvent
        switch envelope.kind {
        case .lifecycle:
            switch envelope.lifecycleEvent {
            case .sessionStarted: event = .sessionStarted
            case .promptSubmitted: event = .promptSubmitted
            case .turnCompleted: event = .turnCompleted
            case .turnFailed: event = .turnFailed
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
        }

        applyEvent(event, to: sessionID)
    }

    private func markActive(sessionID: UUID) {
        if let index = sessions.firstIndex(where: { $0.id == sessionID }),
           sessions[index].bridgeStatus != .active {
            sessions[index].bridgeStatus = .active
        }
    }

    private func applyEvent(_ event: SessionLifecycleEvent, to sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }

        if case .artifactLinked(let artifact) = event {
            appendArtifact(artifact, toSessionAt: index)
            notifyLifecycle(sessionID: sessionID, event: event)
            return
        }

        var state = SessionLifecycleState(
            activity: sessions[index].activity,
            attention: sessions[index].attention,
            summary: sessions[index].summary,
            workingDirectoryPath: sessions[index].workingDirectory.path
        )
        state.apply(event)
        sessions[index].activity = state.activity
        sessions[index].attention = state.attention
        sessions[index].summary = state.summary
        if let path = state.workingDirectoryPath {
            sessions[index].workingDirectory = URL(fileURLWithPath: path)
        }

        notifyLifecycle(sessionID: sessionID, event: event)
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
