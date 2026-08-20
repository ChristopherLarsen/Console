import Foundation

@MainActor
protocol AudioCuePlaying {
    func warmUp()
    func play(_ cue: AppSettings.CueSound, volume: Float)
    func stop()
}
