import AVFoundation
import Speech

/// Centralized owner of the app's single AVAudioEngine and listening mode lifecycle.
@Observable
@MainActor
final class AudioSessionController {
    static let shared = AudioSessionController()

    #if DEBUG
    /// When true, audio engine operations are stubbed out for unit testing.
    static var _unitTestMode = false
    #endif

    private var audioEngine: AVAudioEngine
    private(set) var activeMode: (any ListeningMode)?
    private(set) var isEngineRunning: Bool = false
    private var isMicTapInstalled: Bool = false
    /// Modes preempted by the active mode, most recently suspended last.
    /// Restored in reverse order as active modes release.
    private(set) var suspendedModes: [any ListeningMode] = []
    private var audioContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private(set) var currentAudioLevel: Float = 0.0
    private var configChangeObserver: NSObjectProtocol?

    private init() {
        audioEngine = AVAudioEngine()
        #if DEBUG
        if !Self._unitTestMode {
            observeConfigurationChanges()
        }
        #else
        observeConfigurationChanges()
        #endif
    }

    // MARK: - Engine Management

    /// Starts the audio engine so audio cues can play immediately. Does NOT install
    /// the mic tap — the microphone stays off until a listening mode is requested.
    func prewarmEngine() {
        guard !isEngineRunning else { return }

        #if DEBUG
        if Self._unitTestMode {
            isEngineRunning = true
            return
        }
        #endif

        _ = audioEngine.inputNode

        audioEngine.prepare()
        do {
            try audioEngine.start()
            isEngineRunning = true
            printDebug("[AudioSession] Engine prewarmed and running")
        } catch {
            printDebug("[AudioSession] Failed to start engine: \(error)")
        }
    }

    /// Installs the mic input tap so audio buffers flow to the active mode.
    /// Called only from requestMode(), keeping the mic off until listening actually starts.
    private func installMicTap() {
        guard !isMicTapInstalled else { return }

        #if DEBUG
        if Self._unitTestMode {
            isMicTapInstalled = true
            return
        }
        #endif

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            printDebug("[AudioSession] Invalid audio input format")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.audioContinuation?.yield(buffer)

            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }
            let data = UnsafeBufferPointer(start: channelData, count: frames)
            let sumOfSquares = data.reduce(Float(0)) { $0 + $1 * $1 }
            let rms = sqrt(sumOfSquares / Float(frames))

            Task { @MainActor [weak self] in
                self?.currentAudioLevel = rms
            }
        }
        isMicTapInstalled = true
    }

    private func removeMicTap() {
        guard isMicTapInstalled else { return }
        #if DEBUG
        if !Self._unitTestMode {
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        #else
        audioEngine.inputNode.removeTap(onBus: 0)
        #endif
        isMicTapInstalled = false
        currentAudioLevel = 0.0
    }

    /// Stops the engine, removes the mic tap, deactivates any active mode, and resets all state.
    func shutdown() async {
        if let mode = activeMode {
            await mode.deactivate()
        }
        activeMode = nil
        suspendedModes = []

        audioContinuation?.finish()
        audioContinuation = nil

        #if DEBUG
        if !Self._unitTestMode { audioEngine.stop() }
        #else
        audioEngine.stop()
        #endif
        removeMicTap()
        isEngineRunning = false
        printDebug("[AudioSession] Shutdown complete")
    }

    /// Deactivates the active mode and discards any suspended mode. Stops the engine.
    func stopAll() async {
        if let mode = activeMode {
            await mode.deactivate()
            activeMode = nil
        }
        suspendedModes = []

        audioContinuation?.finish()
        audioContinuation = nil

        #if DEBUG
        if !Self._unitTestMode { audioEngine.stop() }
        #else
        audioEngine.stop()
        #endif
        removeMicTap()
        isEngineRunning = false
        printDebug("[AudioSession] All modes stopped")
    }

    // MARK: - Mode Transitions

    /// Requests activation of a listening mode, preempting or denying based on priority.
    @discardableResult
    func requestMode(_ mode: any ListeningMode) async -> Bool {
        if let current = activeMode {
            guard mode.priority >= current.priority else {
                printDebug("[AudioSession] Mode request denied: \(mode.modeIdentifier) (active: \(current.modeIdentifier))")
                return false
            }

            printDebug("[AudioSession] Deactivating mode: \(current.modeIdentifier)")
            await current.deactivate()

            // An exclusive mode suspends what it preempts — both the primary
            // command mode and an equal-priority exclusive mode (e.g. field
            // dictation over note dictation) — so the preempted mode resumes
            // when the winner releases.
            let shouldSuspend = current.priority == .primary && mode.priority == .exclusive
                || current.priority == .exclusive && mode.priority == .exclusive
            if shouldSuspend {
                suspendedModes.append(current)
                printDebug("[AudioSession] Suspended mode: \(current.modeIdentifier)")
            }
        }

        if !isEngineRunning {
            prewarmEngine()
            guard isEngineRunning else { return false }
        }

        // Install the mic tap now — this is the first moment the microphone is needed.
        installMicTap()
        guard isMicTapInstalled else { return false }

        let stream = createAudioStream()
        printDebug("[AudioSession] Activating mode: \(mode.modeIdentifier)")
        await mode.activate(audioStream: stream)
        activeMode = mode
        return true
    }

    /// Releases the active mode and restores any suspended mode, or stops the engine.
    func releaseMode(_ mode: any ListeningMode) async {
        guard activeMode === mode else { return }

        printDebug("[AudioSession] Deactivating mode: \(mode.modeIdentifier)")
        await mode.deactivate()
        activeMode = nil

        if let suspended = suspendedModes.popLast() {
            printDebug("[AudioSession] Restoring suspended mode: \(suspended.modeIdentifier)")
            await requestMode(suspended)
        } else {
            audioContinuation?.finish()
            audioContinuation = nil
            #if DEBUG
            if !Self._unitTestMode { audioEngine.stop() }
            #else
            audioEngine.stop()
            #endif
            removeMicTap()
            isEngineRunning = false
            printDebug("[AudioSession] No pending modes, engine stopped")
        }
    }

    /// Removes a mode from the suspended stack without activating it.
    /// Used when a suspended mode's owner (e.g. the note panel) is dismissed.
    func discardSuspendedMode(_ mode: any ListeningMode) {
        suspendedModes.removeAll { $0 === mode }
    }

    private func createAudioStream() -> AsyncStream<AVAudioPCMBuffer> {
        audioContinuation?.finish()
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        audioContinuation = continuation
        return stream
    }

    // MARK: - Permissions

    /// Checks mic and speech recognizer authorization status.
    func checkAudioPermissions() -> Bool {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard micStatus == .authorized else { return false }
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        guard speechStatus == .authorized else { return false }
        return true
    }

    // MARK: - Audio Configuration Changes

    private func observeConfigurationChanges() {
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handleConfigurationChange()
            }
        }
    }

    /// Responds to audio device changes by cleanly shutting down the active session.
    private func handleConfigurationChange() async {
        guard isEngineRunning else { return }
        printDebug("[AudioSession] Audio configuration changed, shutting down")
        await shutdown()
    }
}
