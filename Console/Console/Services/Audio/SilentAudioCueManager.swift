import Foundation

@MainActor
final class SilentAudioCueManager: AudioCuePlaying {
    static let shared = SilentAudioCueManager()
    func warmUp() {}
    func play(_ cue: AppSettings.CueSound, volume: Float) {}
    func stop() {}
}
