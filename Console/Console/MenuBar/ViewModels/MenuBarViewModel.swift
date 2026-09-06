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
        let noteDictationActive = AudioSessionController.shared.activeMode?.modeIdentifier == "noteDictation"

        if listeningState == .off && !noteDictationActive {
            startListening()
        } else {
            stopListening()
        }
    }

    func startListening() {
        if NotePanelController.shared.isShowing && NotePanelController.shared.isDictationSuspended {
            resumeWithNoteDictation()
            return
        }

        guard let commandMode else {
            showWarning("Listening services not ready. Try again.")
            return
        }
        guard let wakeWordManager else {
            showWarning("Wake word data not loaded. Try again.")
            return
        }

        let enabled = wakeWordManager.enabledWords
        if enabled.isEmpty {
            showWarning("No trigger words configured.")
            return
        }

        guard AudioSessionController.shared.checkAudioPermissions() else {
            showWarning("Microphone or Speech Recognition permission required.")
            return
        }

        commandMode.updateWakeWords(enabled, allWakeWords: wakeWordManager.wakeWords.map(\.word))
        Task {
            let success = await AudioSessionController.shared.requestMode(commandMode)
            if success {
                listeningState = .passive
                startSleepTimer()
            } else {
                listeningState = .off
                showWarning("Could not start audio session.")
            }
        }
    }

    private func resumeWithNoteDictation() {
        guard let commandMode, let wakeWordManager else {
            showWarning("Listening services not ready. Try again.")
            return
        }

        guard AudioSessionController.shared.checkAudioPermissions() else {
            showWarning("Microphone or Speech Recognition permission required.")
            return
        }

        let enabled = wakeWordManager.enabledWords
        commandMode.updateWakeWords(enabled, allWakeWords: wakeWordManager.wakeWords.map(\.word))

        Task {
            // Start command mode first so it becomes the suspended mode behind note dictation
            let success = await AudioSessionController.shared.requestMode(commandMode)
            guard success else {
                listeningState = .off
                showWarning("Could not start audio session.")
                return
            }
            // Resume note dictation (preempts command mode, which becomes suspended)
            await NotePanelController.shared.resumeDictation()
            listeningState = .passive
            startSleepTimer()
        }
    }

    private func showWarning(_ message: String) {
        warningMessage = message
        VisualFeedbackService.shared.show(.warning(message))
    }

    func stopListening() {
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
        listeningState = .passive
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
        listeningState = .passive
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
        listeningState = .passive
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
        listeningState = .passive
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
        listeningState = .passive
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
        guard let modelContext else { return [] }
        let includeBuiltIn = UserDefaults.standard.bool(forKey: "enableBuiltInCommands")
        let predicate: Predicate<Command>
        if includeBuiltIn {
            predicate = #Predicate<Command> { $0.isEnabled }
        } else {
            predicate = #Predicate<Command> { $0.isEnabled && $0.catalogVersion == nil }
        }
        var descriptor = FetchDescriptor<Command>(predicate: predicate, sortBy: [SortDescriptor(\.name)])
        descriptor.fetchLimit = 50
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    // MARK: - Voice Pipeline

    private func handleWakeWordDetected(wakeWord: String) {
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
            if tfMatcher.bestMatch(for: text, availableIn: .primary) != nil {
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

        let triggerWord = lastDetectedWakeWord ?? ""
        let rawTranscript = lastRawTranscript ?? text

        // Check ConsoleCommands first (they take priority)
        let tfMatcher = ConsoleCommandMatcher(confidenceThreshold: 0.90)
        if let match = tfMatcher.bestMatch(for: text, availableIn: .primary) {
            lastMatchResult = "Built-in: \(match.command.name)"
            SoundFeedbackService.shared.play(.commandIdentified)
            RecentCommandsController.shared.dismiss()

            Task {
                _ = await match.command.handler()
                if self.listeningState != .off { self.listeningState = .passive }
                // Log the execution
                logCommandExecution(
                    triggerWord: triggerWord,
                    rawTranscript: rawTranscript,
                    strippedTranscript: text,
                    matchedCommand: "[Built-in] \(match.command.name)",
                    confidence: 1.0,
                    result: .success,
                    duration: 0,
                    error: nil,
                    commandType: .console
                )
            }
            return true
        }

        return false
    }

    private func logBuiltIn(triggerWord: String, rawTranscript: String, strippedTranscript: String, command: String) {
        logCommandExecution(
            triggerWord: triggerWord, rawTranscript: rawTranscript,
            strippedTranscript: strippedTranscript, matchedCommand: command,
            confidence: 1.0, result: .success, duration: 0, error: nil
        )
    }

    private func bringMainWindowToFront() {
        ConsoleWindowManager.bringToFront("main")
    }

    private func handleCommandTranscribed(_ text: String) {
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
            listeningState = .passive
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
        let errorMsg = run.result.failedSteps.first?.message
        let logResult: CommandLogResult = run.result.overallSuccess ? .success : .failed
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
