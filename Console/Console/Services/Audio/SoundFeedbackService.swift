import Foundation

enum SoundFeedbackEvent {
    case wakeWordDetected
    case commandIdentified
    case commandNotRecognized
    case allCommandsCompleted
    case authorizationRequested
    case authorizationGranted
    case authorizationDenied
    case noteActivated
    case noteCommandRecognized
    case noteFormatStarted
    case noteFormatCompleted
}

@Observable
@MainActor
final class SoundFeedbackService {
    static let shared: SoundFeedbackService = {
        let isUnitTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let player: any AudioCuePlaying = isUnitTesting ? SilentAudioCueManager.shared : AudioCueManager.shared
        return SoundFeedbackService(audioCuePlayer: player)
    }()

    private let audioCuePlayer: any AudioCuePlaying

    init(audioCuePlayer: any AudioCuePlaying) {
        self.audioCuePlayer = audioCuePlayer
    }

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "soundFeedbackEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "soundFeedbackEnabled")
    }

    private var volume: Float {
        UserDefaults.standard.object(forKey: "feedbackSoundVolume") == nil
            ? 0.7
            : Float(UserDefaults.standard.double(forKey: "feedbackSoundVolume"))
    }

    func play(_ event: SoundFeedbackEvent) {
        guard isEnabled else { return }
        let cue = resolvedCue(for: event)
        audioCuePlayer.play(cue, volume: volume)
    }

    func previewCue(_ selection: AppSettings.CueSound) {
        audioCuePlayer.play(selection, volume: volume)
    }

    func resetDefaults() {
        UserDefaults.standard.set(true, forKey: "soundFeedbackEnabled")
        UserDefaults.standard.set(AppSettings.CueSound.fishListening.rawValue, forKey: "cueTriggerRecognized")
        UserDefaults.standard.set(AppSettings.CueSound.happyFish.rawValue, forKey: "cueCommandRecognized")
        UserDefaults.standard.set(AppSettings.CueSound.sadFish.rawValue, forKey: "cueCommandNotRecognized")
        UserDefaults.standard.set(0.7, forKey: "feedbackSoundVolume")
        UserDefaults.standard.synchronize()
    }

    // MARK: - Sound Resolution

    private func resolvedCue(for event: SoundFeedbackEvent) -> AppSettings.CueSound {
        switch event {
        case .wakeWordDetected:
            return resolvedCue(forKey: "cueTriggerRecognized", default: .fishListening)
        case .commandIdentified, .allCommandsCompleted:
            return resolvedCue(forKey: "cueCommandRecognized", default: .happyFish)
        case .commandNotRecognized:
            return resolvedCue(forKey: "cueCommandNotRecognized", default: .sadFish)
        case .authorizationRequested:
            return resolvedCue(forKey: "cueCommandNotRecognized", default: .sadFish)
        case .authorizationGranted:
            return resolvedCue(forKey: "cueCommandRecognized", default: .happyFish)
        case .authorizationDenied:
            return resolvedCue(forKey: "cueCommandNotRecognized", default: .sadFish)
        case .noteActivated:
            return resolvedCue(forKey: "cueTriggerRecognized", default: .fishListening)
        case .noteCommandRecognized:
            return resolvedCue(forKey: "cueCommandRecognized", default: .happyFish)
        case .noteFormatStarted:
            return resolvedCue(forKey: "cueCommandNotRecognized", default: .sadFish)
        case .noteFormatCompleted:
            return resolvedCue(forKey: "cueCommandRecognized", default: .happyFish)
        }
    }

    private func resolvedCue(forKey key: String, default fallback: AppSettings.CueSound) -> AppSettings.CueSound {
        let raw = UserDefaults.standard.string(forKey: key) ?? fallback.rawValue
        return AppSettings.CueSound(rawValue: raw) ?? fallback
    }
}
