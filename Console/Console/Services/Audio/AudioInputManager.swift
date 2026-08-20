import Foundation
import AVFoundation
import AppKit

enum AudioInputError: Error {
    case permissionDenied
}

@Observable
class AudioInputManager {
    private let audioEngine = AVAudioEngine()
    private var inputNode: AVAudioInputNode?
    private var bufferHandler: ((AVAudioPCMBuffer) -> Void)?
    private(set) var isCapturing = false
    private var shouldRestoreAfterInterruption = false
    
    var audioLevel: Float = 0.0
    var lastInterruption: String?
    
    /// Always checks the system source of truth - no caching.
    var isMicrophoneAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
    
    init() {
        observeAudioSessionEvents()
    }
    
    func openSystemPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }
    
    func startCapturing(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        guard isMicrophoneAuthorized else {
            printDebug("AudioInputManager: startCapturing blocked, permission denied")
            throw AudioInputError.permissionDenied
        }
        
        if isCapturing {
            stopCapturing()
        }

        bufferHandler = onBuffer
        try configureAudioSessionIfNeeded()

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            printDebug("AudioInputManager: invalid audio input format (channels: \(recordingFormat.channelCount), sampleRate: \(recordingFormat.sampleRate))")
            return
        }
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            self.calculateAudioLevel(buffer)
            onBuffer(buffer)
        }
        
        audioEngine.prepare()
        try audioEngine.start()
        isCapturing = true
        printDebug("AudioInputManager: capturing started, format=\(recordingFormat)")
    }
    
    func stopCapturing() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        audioLevel = 0.0
        isCapturing = false
        printDebug("AudioInputManager: capturing stopped")
    }
    
    private func calculateAudioLevel(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let channelDataArray = UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength))
        
        var rms: Float = 0.0
        if buffer.frameLength > 0 {
            let sumOfSquares = channelDataArray.reduce(0) { $0 + $1 * $1 }
            rms = sqrt(sumOfSquares / Float(buffer.frameLength))
        }
        
        DispatchQueue.main.async {
            self.audioLevel = rms
        }
    }

    // MARK: - Session / Interruption Handling

    private func observeAudioSessionEvents() {
        #if os(iOS)
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }
        #else
        // macOS: Observe audio device changes via CoreAudio notifications
        // For now, we handle configuration changes when they occur during capture
        #endif
    }

    private func configureAudioSessionIfNeeded() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers, .allowBluetooth])
        try session.setPreferredSampleRate(16000)
        try session.setActive(true, options: [])
        #endif
    }

    private func handleInterruption(_ notification: Notification) {
        guard isCapturing else { return }
        stopCapturing()
        shouldRestoreAfterInterruption = true
        lastInterruption = "Audio session interrupted"
    }

    private func handleConfigurationChange() {
        guard shouldRestoreAfterInterruption else { return }
        do {
            if let handler = bufferHandler {
                try startCapturing(onBuffer: handler)
            }
            shouldRestoreAfterInterruption = false
            lastInterruption = nil
        } catch {
            lastInterruption = "Failed to restore audio after configuration change"
        }
    }
}
