import AppKit
import Foundation
import SwiftTerm

enum SessionCreationError: LocalizedError {
    case claudeNotFound
    case pluginAssemblyFailed

    var errorDescription: String? {
        switch self {
        case .claudeNotFound:
            return "Claude Code was not found on this Mac. Install Claude Code or pick its executable in Settings → Claude Executable."
        case .pluginAssemblyFailed:
            return "Console could not prepare the local bridge for this session. The terminal will still work, but session status is unavailable."
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

    @ObservationIgnored let locator: ClaudeExecutableLocator
    @ObservationIgnored private var launcher: any SessionProcessLaunching

    // Bridge plumbing. Tokens and event ids live only in memory.
    @ObservationIgnored private var sessionTokens: [UUID: String] = [:]
    @ObservationIgnored private var router: SessionEventRouter!
    @ObservationIgnored private var socketServer: SessionBridgeSocketServer?
    @ObservationIgnored private var socketPath: String?
    @ObservationIgnored private lazy var pluginAssembler = ConsoleClaudePluginAssembler()

    /// Ephemeral root shared by the socket and assembled plugin copies.
    @ObservationIgnored private let ephemeralRoot: URL
    @ObservationIgnored private var assembledPluginRoot: URL?
    @ObservationIgnored private var inputMonitor: Any?

    static let gracefulStopGraceSeconds: UInt64 = 3

    init(
        launcher: any SessionProcessLaunching,
        locator: ClaudeExecutableLocator
    ) {
        self.launcher = launcher
        self.locator = locator
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

    func session(withID id: UUID) -> ConsoleSession? {
        sessions.first(where: { $0.id == id })
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

    /// Creates and launches a new Claude session.
    @discardableResult
    func createSession(name: String, workingDirectory: URL) throws -> UUID {
        guard let claudePath = locator.locate() else {
            throw SessionCreationError.claudeNotFound
        }

        startBridgeIfNeeded()

        let consoleID = UUID()
        let claudeID = UUID()
        let displayName = Self.uniquedName(name.trimmingCharacters(in: .whitespacesAndNewlines), existingNames: activeNames)

        let terminalView = launcher.makeTerminalView()

        let coordinator = SessionTerminalCoordinator(sessionID: consoleID, store: self)
        terminalView.processDelegate = coordinator

        let token = Self.generateToken()
        let bridgeSocketPath = socketPath ?? ""
        let helperPath = Self.helperPath()

        let session = ConsoleSession(
            id: consoleID,
            claudeSessionID: claudeID,
            name: displayName,
            workingDirectory: workingDirectory,
            terminalView: terminalView,
            activity: .starting,
            attention: .none,
            summary: nil,
            artifacts: [],
            bridgeStatus: socketServer != nil ? .unknown : .unavailable
        )
        sessions.append(session)
        sessionTokens[consoleID] = token
        select(sessionID: consoleID)

        do {
            let pluginRoot = try materializePluginRoot()
            try launcher.launch(
                executable: claudePath,
                arguments: Self.launchArguments(
                    claudeSessionID: claudeID,
                    name: displayName,
                    pluginDirectory: pluginRoot
                ),
                environment: [
                    "CONSOLE_TERM_BRIDGE_HELPER": helperPath,
                    "CONSOLE_TERM_BRIDGE_SOCKET": bridgeSocketPath,
                    "CONSOLE_TERM_BRIDGE_SESSION_ID": consoleID.uuidString,
                    "CONSOLE_TERM_BRIDGE_TOKEN": token,
                ].filterEnvironmentValues(),
                workingDirectory: workingDirectory.path,
                terminalView: terminalView
            )
        } catch {
            if let index = sessions.firstIndex(where: { $0.id == consoleID }) {
                sessions[index].activity = .error
            }
            throw error
        }
        return consoleID
    }

    /// Exact launch arguments: identity, display name, bundled plugin, and
    /// preapproval of only the three Console MCP tool names.
    static func launchArguments(claudeSessionID: UUID, name: String, pluginDirectory: String) -> [String] {
        [
            "--session-id", claudeSessionID.uuidString,
            "--name", name,
            "--plugin-dir", pluginDirectory,
        ] + ["--allowedTools"] + ConsoleClaudePluginAssembler.allowedToolNames
    }

    private func materializePluginRoot() throws -> String {
        if let existing = assembledPluginRoot {
            return existing.path
        }
        do {
            let root = try pluginAssembler.materialize(in: ephemeralRoot)
            assembledPluginRoot = root
            return root.path
        } catch {
            throw SessionCreationError.pluginAssemblyFailed
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

    /// Graceful stop (SIGTERM). UI confirms first for Working / Needs Approval /
    /// Needs Input sessions; this entry point runs after that confirmation.
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
    /// complete within the grace period.
    func forceStop(id: UUID) {
        awaitingForceStopSessionID = nil
        guard let session = session(withID: id), session.activity != .exited else { return }
        let pid = session.terminalView.process?.shellPid ?? 0
        guard pid > 0 else {
            handleProcessTerminated(sessionID: id)
            return
        }
        kill(pid, SIGKILL)
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
            guard let session = self.session(withID: id),
                  session.activity != .exited,
                  kill(pid, 0) == 0 else { return }
            self.awaitingForceStopSessionID = id
        }
    }

    /// Removes an exited session (and its retained scrollback) from the list.
    func removeSession(id: UUID) {
        guard let session = session(withID: id), session.activity == .exited else { return }
        sessions.removeAll(where: { $0.id == id })
        sessionTokens.removeValue(forKey: id)
        router.forget(sessionID: id)
        if selectedSessionID == id {
            selectedSessionID = sessions.first?.id
        }
    }

    func handleProcessTerminated(sessionID: UUID) {
        applyEvent(.processTerminated, to: sessionID)
    }

    /// Stops every running session. Used on actual app termination only —
    /// hiding the window leaves everything running.
    func terminateAll() {
        for session in sessions where session.activity != .exited {
            let pid = session.terminalView.process?.shellPid ?? 0
            if pid > 0 {
                kill(pid, SIGKILL)
            }
            handleProcessTerminated(sessionID: session.id)
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
        session.terminalView.send(data: bytes[...])
        applyEvent(.promptSubmitted, to: sessionID)
        return .submitted
    }

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
