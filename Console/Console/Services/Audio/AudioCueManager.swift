import Foundation
import AVFoundation

@MainActor
final class AudioCueManager: AudioCuePlaying {
    static let shared = AudioCueManager()

    private var playerCache: [String: AVAudioPlayer] = [:]
    private var isWarmedUp = false

    /// Preloads all bundled cue sounds and primes the audio hardware.
    /// Fix #1: AVAudioPlayer loads files into memory by default
    /// Fix #2: Caches all AVAudioPlayer instances in playerCache
    /// Fix #3: Activates audio hardware by playing silent audio
    func warmUp() {
        guard !isWarmedUp else { return }
        isWarmedUp = true

        // Pre-load and cache all sounds
        var loadedCount = 0
        for cue in AppSettings.CueSound.allCases {
            guard let player = loadPlayer(for: cue) else { continue }
            player.prepareToPlay()
            playerCache[cue.rawValue] = player
            loadedCount += 1
        }

        // Activate audio hardware by playing a brief silent tone
        activateAudioHardware()

        printDebug("[AudioCueManager] Warmed up: loaded \(loadedCount) sounds into cache")
    }

    func play(_ cue: AppSettings.CueSound, volume: Float) {
        if !isWarmedUp { warmUp() }

        if let cached = playerCache[cue.rawValue] {
            cached.volume = volume
            cached.currentTime = 0
            cached.play()
            return
        }

        guard let player = loadPlayer(for: cue) else { return }
        player.volume = volume
        player.prepareToPlay()
        player.play()
        playerCache[cue.rawValue] = player
    }

    func stop() {
        for player in playerCache.values where player.isPlaying {
            player.stop()
        }
    }

    // MARK: - Private

    /// Activates audio hardware by playing a brief silent tone.
    /// This eliminates pops/crackling on the first real sound playback.
    private func activateAudioHardware() {
        // Create a minimal silent audio buffer (10ms of silence at 44.1kHz)
        let sampleRate: Double = 44100
        let duration: Double = 0.01
        let frameCount = Int(sampleRate * duration)
        let channelCount = 2 // stereo

        let silentData = Data(count: frameCount * channelCount * MemoryLayout<Int16>.size)

        // Create a minimal WAV file in memory
        var wavData = Data()

        // RIFF header
        wavData.append(contentsOf: "RIFF".utf8)
        let fileSize = UInt32(36 + silentData.count)
        withUnsafeBytes(of: fileSize.littleEndian) { wavData.append(contentsOf: $0) }
        wavData.append(contentsOf: "WAVE".utf8)

        // fmt chunk
        wavData.append(contentsOf: "fmt ".utf8)
        withUnsafeBytes(of: UInt32(16).littleEndian) { wavData.append(contentsOf: $0) } // fmt size
        withUnsafeBytes(of: UInt16(1).littleEndian) { wavData.append(contentsOf: $0) }  // PCM format
        withUnsafeBytes(of: UInt16(channelCount).littleEndian) { wavData.append(contentsOf: $0) } // channels
        withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { wavData.append(contentsOf: $0) } // sample rate
        let byteRate = UInt32(sampleRate * Double(channelCount) * 2)
        withUnsafeBytes(of: byteRate.littleEndian) { wavData.append(contentsOf: $0) } // byte rate
        withUnsafeBytes(of: UInt16(channelCount * 2).littleEndian) { wavData.append(contentsOf: $0) } // block align
        withUnsafeBytes(of: UInt16(16).littleEndian) { wavData.append(contentsOf: $0) } // bits per sample

        // data chunk
        wavData.append(contentsOf: "data".utf8)
        withUnsafeBytes(of: UInt32(silentData.count).littleEndian) { wavData.append(contentsOf: $0) }
        wavData.append(silentData)

        // Play the silent sound at volume 0 to wake up the audio hardware
        if let silentPlayer = try? AVAudioPlayer(data: wavData) {
            silentPlayer.volume = 0.0
            silentPlayer.prepareToPlay()
            silentPlayer.play()
        }
    }

    private func loadPlayer(for cue: AppSettings.CueSound) -> AVAudioPlayer? {
        guard let url = soundURL(for: cue) else { return nil }
        return try? AVAudioPlayer(contentsOf: url)
    }

    private func soundURL(for cue: AppSettings.CueSound) -> URL? {
        if cue.isBundled {
            return Bundle.main.url(forResource: cue.soundName, withExtension: "wav")
        }
        let systemPath = "/System/Library/Sounds/\(cue.soundName).aiff"
        let url = URL(fileURLWithPath: systemPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
