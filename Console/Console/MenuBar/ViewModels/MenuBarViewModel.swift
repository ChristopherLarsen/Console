import Foundation
import Observation
import SwiftUI
import SwiftData

@Observable
@MainActor
final class MenuBarViewModel {

    static var shared: MenuBarViewModel?

    // MARK: - State

    var listeningState: ListeningState = .off
    var warningMessage: String?
    var lastDetectedTrigger: String = ""
    var modelContext: ModelContext?
    var wakeWordManager: WakeWordManager?

    private(set) var recentLogs: [CommandExecutionLog] = []

    // MARK: - Dependencies

    private let settings = AppSettings()
    private let logManager = CommandLogFileManager.shared
    private var commandMode: CommandListeningMode?
    private var localCommandExecutor: (any CommandRunning)?
    private var aiProviderManager: AIProviderManager?
    private var commandMatcher: CommandMatcher?
    @ObservationIgnored private var stopListeningObserver: Any?
    @ObservationIgnored private var stopExecutionObserver: Any?
    @ObservationIgnored private var hotkeyObserver: Any?
    @ObservationIgnored private var showNoteObserver: Any?
    @ObservationIgnored private var voiceActivityObserver: Any?
    @ObservationIgnored private var sleepCheckTask: Task<Void, Never>?
    @ObservationIgnored private var lastVolatileTextChange: Date = Date()
    /// Bumped on every start/stop so a late start task cannot resurrect a stopped session.
    @ObservationIgnored private var listeningGeneration = 0

    // Logging context captured across the voice pipeline
    private var lastDetectedWakeWord: String?
    private var lastRawTranscript: String?
    private(set) var lastStrippedTranscript: String = ""
    private(set) var lastMatchResult: String = ""
    private(set) var fuzzyMatchInputText: String = ""

    init() {
        stopListeningObserver = NotificationCenter.default.addObserver(
            forName: .stopListeningRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stopListening()
            }
        }
        stopExecutionObserver = NotificationCenter.default.addObserver(
            forName: .stopExecutionRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.localCommandExecutor?.cancelExecution()
            }
        }
        hotkeyObserver = NotificationCenter.default.addObserver(
            forName: .globalHotkeyPressed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let exclusiveModeActive = AudioSessionController.shared.activeMode?.priority == .exclusive
                if self.listeningState == .off && !exclusiveModeActive {
                    self.startListening()
                } else {
                    self.bringMainWindowToFront()
                    if NotePanelController.shared.isShowing,
                       NoteViewModel.shared?.isPinned == false {
                        NotePanelController.shared.bringToFront()
                    }
                }
            }
        }
        showNoteObserver = NotificationCenter.default.addObserver(
            forName: .showNoteRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.openNote()
            }
        }
        voiceActivityObserver = NotificationCenter.default.addObserver(
            forName: .voiceActivityDetected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recordVoiceActivity()
            }
        }
    }

    // MARK: - Listening Control

    func setListeningServices(
        localCommandExecutor: any CommandRunning,
        aiProviderManager: AIProviderManager,
        transcriptSource: TranscriptSource? = nil
    ) {
        self.localCommandExecutor = localCommandExecutor
        self.aiProviderManager = aiProviderManager
        self.commandMatcher = CommandMatcher(
            confidenceThreshold: settings.confidenceThreshold
        )

        let mode = CommandListeningMode(transcriptSource: transcriptSource)
        mode.onWakeWordDetected = { [weak self] wakeWord in
            self?.recordVoiceActivity()
            self?.handleWakeWordDetected(wakeWord: wakeWord)
        }
        mode.onRawAndStrippedText = { [weak self] raw, stripped in
            self?.recordVoiceActivity()
            self?.lastRawTranscript = raw
            self?.lastStrippedTranscript = stripped
        }
        mode.onCommandTranscribed = { [weak self] text in
            self?.handleCommandTranscribed(text)
        }
        mode.onCommandCancelled = { [weak self] in
            guard let self else { return }
            if self.listeningState != .off { self.listeningState = .passive }
        }
        mode.onEagerMatchAttempt = { [weak self] text in
            self?.tryEagerMatch(text) ?? false
        }
        self.commandMode = mode
    }

    func toggleListening() {
        Task { await toggleListeningAwaited() }
    }

    @discardableResult
    func toggleListeningAwaited() async -> Bool {
        let noteDictationActive = AudioSessionController.shared.activeMode?.modeIdentifier == "noteDictation"

        if listeningState == .off && !noteDictationActive {
            return await startListeningAwaited()
        }
        stopListening()
        return false
    }

    func startListening() {
        Task { await startListeningAwaited() }
    }

    /// Starts listening and waits until the audio mode is actually active, so
    /// callers (App Intents) can report truthful state.
    @discardableResult
    func startListeningAwaited() async -> Bool {
        if NotePanelController.shared.isShowing && NotePanelController.shared.isDictationSuspended {
            await resumeWithNoteDictation()
            return listeningState != .off
        }

        guard let commandMode else {
            showWarning("Listening services not ready. Try again.")
            return false
        }
        guard let wakeWordManager else {
            showWarning("Wake word data not loaded. Try again.")
            return false
        }

        let enabled = wakeWordManager.enabledWords
        if enabled.isEmpty {
            showWarning("No trigger words configured.")
            return false
        }

        guard AudioSessionController.shared.checkAudioPermissions() else {
            showWarning("Microphone or Speech Recognition permission required.")
            return false
        }

        listeningGeneration += 1
        let generation = listeningGeneration

        commandMode.updateWakeWords(enabled, allWakeWords: enabled)
        let success = await AudioSessionController.shared.requestMode(commandMode)
        guard generation == listeningGeneration else {
            // A stop happened while the mode request was in flight; stop wins.
            if success {
                await AudioSessionController.shared.releaseMode(commandMode)
            }
            return false
        }
        if success {
            listeningState = .passive
            startSleepTimer()
        } else {
            listeningState = .off
            showWarning("Could not start audio session.")
        }
        return success
    }

    private func resumeWithNoteDictation() async {
        guard let commandMode, let wakeWordManager else {
            showWarning("Listening services not ready. Try again.")
            return
        }

        guard AudioSessionController.shared.checkAudioPermissions() else {
            showWarning("Microphone or Speech Recognition permission required.")
            return
        }

        let enabled = wakeWordManager.enabledWords
        commandMode.updateWakeWords(enabled, allWakeWords: enabled)

        listeningGeneration += 1
        let generation = listeningGeneration

        // Start command mode first so it becomes the suspended mode behind note dictation
        let success = await AudioSessionController.shared.requestMode(commandMode)
        guard success else {
            guard generation == listeningGeneration else { return }
            listeningState = .off
            showWarning("Could not start audio session.")
            return
        }
        // Resume note dictation (preempts command mode, which becomes suspended)
        await NotePanelController.shared.resumeDictation()
        guard generation == listeningGeneration else { return }
        if listeningState != .off { listeningState = .passive }
        startSleepTimer()
    }

    private func showWarning(_ message: String) {
        warningMessage = message
        VisualFeedbackService.shared.show(.warning(message))
    }

    func stopListening() {
        listeningGeneration += 1

        // Cancel any pending authorization so an approve can no longer resume
        // execution after listening was stopped.
        if AuthorizationManager.shared.isShowingDialog {
            AuthorizationManager.shared.deny()
        }

        let noteShowing = NotePanelController.shared.isShowing

        Task {
            await AudioSessionController.shared.stopAll()
        }

        if noteShowing {
            NotePanelController.shared.markDictationSuspended()
        }

        listeningState = .off
        lastDetectedTrigger = ""
        stopSleepTimer()

        // Stopping listening is also the reachable voice/hotkey stop for an
        // in-flight command execution.
        localCommandExecutor?.cancelExecution()
    }

    func stopExecution() {
        localCommandExecutor?.cancelExecution()
    }

    var isExecutingCommand: Bool {
        localCommandExecutor?.isExecuting == true
    }

    // MARK: - Sleep Timer

    func recordVoiceActivity() {
        lastVolatileTextChange = Date()
    }

    private func startSleepTimer() {
        stopSleepTimer()
        lastVolatileTextChange = Date()
        sleepCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                let isListening = self.listeningState != .off
                let noteActive = NotePanelController.shared.isShowing
                guard isListening || noteActive else { continue }
                let interval = UserDefaults.standard.string(forKey: "sleepAfterInterval") ?? AppSettings.SleepInterval.thirtyMinutes.rawValue
                guard let sleepInterval = AppSettings.SleepInterval(rawValue: interval),
                      let seconds = sleepInterval.seconds else { continue }
                let elapsed = Date().timeIntervalSince(self.lastVolatileTextChange)
                if elapsed >= seconds {
                    if isListening { self.stopListening() }
                    if noteActive { NotePanelController.shared.dismiss() }
                }
            }
        }
    }

    private func stopSleepTimer() {
        sleepCheckTask?.cancel()
        sleepCheckTask = nil
    }

    func openNote() {
        ConsoleWindowManager.bringToFront("note")
        if sleepCheckTask == nil { startSleepTimer() }
    }

    // MARK: - ConsoleCommand Handlers

    func showSettings() async {
        let triggerWord = lastDetectedWakeWord ?? ""
        let rawTranscript = lastRawTranscript ?? ""
        let strippedTranscript = lastStrippedTranscript

        lastMatchResult = "Built-in: Settings"
        logBuiltIn(triggerWord: triggerWord, rawTranscript: rawTranscript,
                   strippedTranscript: strippedTranscript, command: "[Built-in] Settings")

        bringMainWindowToFront()
        ConsoleNavigation.showSettings()
        if listeningState != .off { listeningState = .passive }
    }

    func showRecentCommands() async {
        let triggerWord = lastDetectedWakeWord ?? ""
        let rawTranscript = lastRawTranscript ?? ""
        let strippedTranscript = lastStrippedTranscript

        lastMatchResult = "Built-in: Recent Commands"
        logBuiltIn(triggerWord: triggerWord, rawTranscript: rawTranscript,
                   strippedTranscript: strippedTranscript, command: "[Built-in] Recent Commands")

        let allCommands = fetchEnabledCommands()
        let activeWakeWords = wakeWordManager?.wakeWords.map(\.word) ?? []
        RecentCommandsController.shared.show(
            commands: allCommands,
            wakeWords: activeWakeWords,
            executor: localCommandExecutor
        )
        if listeningState != .off { listeningState = .passive }
    }

    func disableSoundFeedback() async {
        let triggerWord = lastDetectedWakeWord ?? ""
        let rawTranscript = lastRawTranscript ?? ""
        let strippedTranscript = lastStrippedTranscript

        lastMatchResult = "Built-in: Be Quiet"
        logBuiltIn(triggerWord: triggerWord, rawTranscript: rawTranscript,
                   strippedTranscript: strippedTranscript, command: "[Built-in] Be Quiet")

        UserDefaults.standard.set(false, forKey: "soundFeedbackEnabled")
        UserDefaults.standard.synchronize()
        if listeningState != .off { listeningState = .passive }
    }

    func enableSoundFeedback() async {
        let triggerWord = lastDetectedWakeWord ?? ""
        let rawTranscript = lastRawTranscript ?? ""
        let strippedTranscript = lastStrippedTranscript

        lastMatchResult = "Built-in: Make Some Noise"
        logBuiltIn(triggerWord: triggerWord, rawTranscript: rawTranscript,
                   strippedTranscript: strippedTranscript, command: "[Built-in] Make Some Noise")

        UserDefaults.standard.set(true, forKey: "soundFeedbackEnabled")
        UserDefaults.standard.synchronize()
        SoundFeedbackService.shared.previewCue(.happyFish)
        if listeningState != .off { listeningState = .passive }
    }

    func showNewCommandCreation() async {
        let triggerWord = lastDetectedWakeWord ?? ""
        let rawTranscript = lastRawTranscript ?? ""
        let strippedTranscript = lastStrippedTranscript

        lastMatchResult = "Built-in: New Command"
        logBuiltIn(triggerWord: triggerWord, rawTranscript: rawTranscript,
                   strippedTranscript: strippedTranscript, command: "[Built-in] New Command")

        bringMainWindowToFront()
        ConsoleNavigation.showTerminal(tab: .myCommands)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NotificationCenter.default.post(name: .showCommandCreation, object: nil)
        }
        if listeningState != .off { listeningState = .passive }
    }

    @discardableResult
    func executeLocalCommand(_ command: Command) async -> CommandRun {
        guard let localCommandExecutor else {
            if listeningState != .off { listeningState = .passive }
            return CommandRun(
                id: UUID(),
                result: ExecutionResult(
                    command: command,
                    logs: [],
                    overallSuccess: false,
                    totalDurationMs: 0
                )
            )
        }

        if localCommandExecutor.isExecuting {
            let run = await localCommandExecutor.execute(command, skipAuthorization: false)
            if listeningState != .off { listeningState = .passive }
            return run
        }

        let authManager = AuthorizationManager.shared

        if authManager.requiresAuthorization(command) {
            listeningState = .awaitingAuthorization
            let authorized = await authManager.requestAuthorization(for: command)
            guard authorized else {
                if listeningState != .off { listeningState = .passive }
                return CommandRun(
                    id: UUID(),
                    result: ExecutionResult(
                        command: command,
                        logs: [],
                        overallSuccess: false,
                        totalDurationMs: 0,
                        authorizationDenied: true
                    )
                )
            }
            // Listening was stopped while the dialog was open: do not resume.
            guard listeningState != .off else {
                return CommandRun(
                    id: UUID(),
                    result: ExecutionResult(
                        command: command,
                        logs: [],
                        overallSuccess: false,
                        totalDurationMs: 0,
                        authorizationDenied: true
                    )
                )
            }
            listeningState = .executing
            let run = await localCommandExecutor.execute(command, skipAuthorization: true)
            if !run.result.alreadyRunning {
                recordExecution(command)
            }
            if listeningState != .off { listeningState = .passive }
            return run
        } else {
            listeningState = .executing
            let run = await localCommandExecutor.execute(command, skipAuthorization: false)
            if !run.result.alreadyRunning {
                recordExecution(command)
            }
            if listeningState != .off { listeningState = .passive }
            return run
        }
    }

    private func recordExecution(_ command: Command) {
        try? modelContext?.save()
    }

    func fetchEnabledCommands() -> [Command] {
        LocalCommandExecutor.fetchEnabledCommands(in: modelContext)
    }

    // MARK: - Voice Pipeline

    private func handleWakeWordDetected(wakeWord: String) {
        // A stop may land between the transcript callback and this handler;
        // never mutate listening state or start capture after .off.
        guard listeningState != .off else { return }
        guard !AuthorizationManager.shared.isShowingDialog else { return }
        lastDetectedTrigger = wakeWord
        lastDetectedWakeWord = wakeWord
        lastStrippedTranscript = ""
        lastMatchResult = ""
        fuzzyMatchInputText = ""
        listeningState = .commandListening
    }

    /// Attempts an eager match with a strict 90% confidence threshold.
    /// Returns true if a match was found, signaling immediate finalization.
    private func tryEagerMatch(_ text: String) -> Bool {
        // Check ConsoleCommands with higher threshold (90%)
        if UserDefaults.standard.bool(forKey: "recognizeBuiltInCommands") {
            let tfMatcher = ConsoleCommandMatcher(confidenceThreshold: 0.90)
            if let match = tfMatcher.bestMatch(for: text, availableIn: .primary),
               !isConsoleCommandDisabled(match.command) {
                return true
            }
        }

        // Try custom command matching at 90% threshold
        let commands = fetchEnabledCommands()
        let eagerMatcher = CommandMatcher(confidenceThreshold: 0.90)
        if eagerMatcher.bestMatch(for: text, in: commands) != nil {
            return true
        }
        return false
    }

    private func handleBuiltInCommand(_ text: String) -> Bool {
        guard UserDefaults.standard.bool(forKey: "recognizeBuiltInCommands") else { return false }
        guard listeningState != .off else { return false }

        // Check ConsoleCommands first (they take priority)
        let tfMatcher = ConsoleCommandMatcher(confidenceThreshold: 0.90)
        if let match = tfMatcher.bestMatch(for: text, availableIn: .primary) {
            // A disabled console command in the Commands list must also disable
            // its registry twin.
            if isConsoleCommandDisabled(match.command) { return false }
            // Single execution owner: while the shared executor is busy, only
            // the stop command may run off-executor; everything else falls
            // through to the executor's occupancy rejection.
            let executorBusy = localCommandExecutor?.isExecuting == true
            if executorBusy && match.command.id != "stop-listening" { return false }

            lastMatchResult = "Built-in: \(match.command.name)"
            SoundFeedbackService.shared.play(.commandIdentified)
            RecentCommandsController.shared.dismiss()

            Task {
                guard self.listeningState != .off else { return }

                // Honor "require authorization for every command" for registry
                // built-ins; the emergency stop stays dialog-free.
                if match.command.id != "stop-listening",
                   AppSettings().requireAuthorizationForAllCommands {
                    let authManager = AuthorizationManager.shared
                    if self.listeningState != .off { self.listeningState = .awaitingAuthorization }
                    let authorized = await authManager.requestAuthorization(for: match.command.asCommand)
                    guard authorized, self.listeningState != .off else {
                        if self.listeningState != .off { self.listeningState = .passive }
                        return
                    }
                }

                _ = await match.command.handler()
                if self.listeningState != .off { self.listeningState = .passive }
                // Logging happens inside the handler's logBuiltIn path; a
                // second log here would double-record every built-in.
            }
            return true
        }

        return false
    }

    // MARK: - Disabled Registry Commands

    /// Payloads of console starter commands the user disabled in the Commands list.
    func disabledConsoleActionPayloads() -> Set<String> {
        guard let modelContext else { return [] }
        let predicate = #Predicate<Command> { $0.isConsole && !$0.isEnabled }
        let descriptor = FetchDescriptor<Command>(predicate: predicate)
        let commands = (try? modelContext.fetch(descriptor)) ?? []
        return Set(commands.compactMap { $0.actions.first?.payload })
    }

    func isConsoleCommandDisabled(_ command: ConsoleCommand) -> Bool {
        guard let action = ConsoleCommandRegistry.consoleAction(for: command.id) else { return false }
        return disabledConsoleActionPayloads().contains(action.rawValue)
    }

    private func logBuiltIn(triggerWord: String, rawTranscript: String, strippedTranscript: String, command: String) {
        logCommandExecution(
            triggerWord: triggerWord, rawTranscript: rawTranscript,
            strippedTranscript: strippedTranscript, matchedCommand: command,
            confidence: 1.0, result: .success, duration: 0, error: nil,
            commandType: .console
        )
    }

    private func bringMainWindowToFront() {
        ConsoleWindowManager.bringToFront("main")
    }

    private func handleCommandTranscribed(_ text: String) {
        // Ignore transcripts already in flight when listening was stopped.
        guard listeningState != .off else { return }

        fuzzyMatchInputText = text
        if handleBuiltInCommand(text) { return }

        let commands = fetchEnabledCommands()
        let levelRaw = UserDefaults.standard.string(forKey: "confidenceLevel") ?? "normal"
        let threshold = AppSettings.ConfidenceLevel(rawValue: levelRaw)?.threshold ?? 0.75
        let matcher = CommandMatcher(confidenceThreshold: threshold)
        let triggerWord = lastDetectedWakeWord ?? ""
        let rawTranscript = lastRawTranscript ?? text

        if let match = matcher.bestMatch(for: text, in: commands) {
            lastMatchResult = "Matched: \(match.command.name) (\(Int(match.confidence * 100))%)"
            SoundFeedbackService.shared.play(.commandIdentified)
            VisualFeedbackService.shared.show(.commandRecognized(match.command.name))
            let executionStart = Date()
            RecentCommandsController.shared.dismiss()
            Task {
                guard self.listeningState != .off else { return }
                let run = await self.executeLocalCommand(match.command)
                self.recordVoiceExecutionLog(
                    run: run,
                    triggerWord: triggerWord,
                    rawTranscript: rawTranscript,
                    strippedTranscript: text,
                    matchedCommand: match.command.name,
                    confidence: match.confidence,
                    duration: Date().timeIntervalSince(executionStart)
                )
            }
        } else {
            lastMatchResult = "No match found"
            logCommandExecution(
                triggerWord: triggerWord,
                rawTranscript: rawTranscript,
                strippedTranscript: text,
                matchedCommand: nil,
                confidence: nil,
                result: .noMatch,
                duration: nil,
                error: nil
            )
            SoundFeedbackService.shared.play(.commandNotRecognized)
            VisualFeedbackService.shared.show(.commandNotRecognized)
            if listeningState != .off { listeningState = .passive }
        }
    }

    // MARK: - Logging

    @discardableResult
    func recordVoiceExecutionLog(
        run: CommandRun,
        triggerWord: String,
        rawTranscript: String,
        strippedTranscript: String,
        matchedCommand: String,
        confidence: Double,
        duration: TimeInterval
    ) -> Bool {
        guard !run.result.alreadyRunning else { return false }

        let logResult: CommandLogResult
        let errorMsg: String?
        if run.result.authorizationDenied {
            logResult = .failed
            errorMsg = "Authorization denied"
        } else if run.result.wasCancelled {
            logResult = .cancelled
            errorMsg = "Cancelled"
        } else {
            logResult = run.result.overallSuccess ? .success : .failed
            errorMsg = run.result.failedSteps.first?.message
        }
        logCommandExecution(
            triggerWord: triggerWord,
            rawTranscript: rawTranscript,
            strippedTranscript: strippedTranscript,
            matchedCommand: matchedCommand,
            confidence: confidence,
            result: logResult,
            duration: duration,
            error: errorMsg
        )
        return true
    }

    private func logCommandExecution(
        triggerWord: String,
        rawTranscript: String,
        strippedTranscript: String,
        matchedCommand: String?,
        confidence: Double?,
        result: CommandLogResult,
        duration: TimeInterval?,
        error: String?,
        commandType: CommandType = .user
    ) {
        guard settings.enableCommandLogging else { return }

        let log = CommandExecutionLog(
            id: UUID(),
            commandType: commandType,
            timestamp: Date(),
            triggerWord: triggerWord,
            rawTranscript: rawTranscript,
            strippedTranscript: strippedTranscript,
            matchedCommand: matchedCommand,
            matchConfidence: confidence,
            executionResult: result,
            executionDuration: duration,
            errorMessage: error
        )
        logManager.saveLog(log)

        recentLogs.insert(log, at: 0)
        if recentLogs.count > 10 { recentLogs.removeLast() }
    }
}
