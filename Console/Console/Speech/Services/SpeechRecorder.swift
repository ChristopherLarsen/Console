import Foundation
import AVFoundation

@available(macOS 26.0, *)
class SpeechRecorder {
    private let transcriber: SpokenWordTranscriber
    private var streamTask: Task<Void, Never>?
    private var audioStream: AsyncStream<AVAudioPCMBuffer>?

    var isTranscriptionPaused: Bool = false

    var story: SpeechStory

    var file: AVAudioFile?
    private let url: URL

    // Playback uses its own engine (separate from the shared mic engine)
    private var playbackEngine: AVAudioEngine?
    var playerNode: AVAudioPlayerNode?

    init(transcriber: SpokenWordTranscriber, story: SpeechStory, audioStream: AsyncStream<AVAudioPCMBuffer>? = nil) {
        self.transcriber = transcriber
        self.story = story
        self.audioStream = audioStream
        self.url = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString)
            .appendingPathExtension(for: .wav)
    }

    /// Begins consuming audio from the external stream and forwarding to the transcriber.
    func record() async throws {
        self.story.url = url
        try await transcriber.setUpTranscriber()

        guard let audioStream else { return }
        streamTask = Task { [weak self] in
            for await buffer in audioStream {
                guard !Task.isCancelled else { break }
                guard let self else { return }
                writeBufferToDisk(buffer: buffer)
                if !self.isTranscriptionPaused {
                    try? await self.transcriber.streamAudioToTranscriber(buffer)
                }
            }
        }
    }

    func stopRecording() async throws {
        streamTask?.cancel()
        streamTask = nil
        story.isDone = true
        try await transcriber.finishTranscribing()
    }

    func playRecording() {
        guard let file else { return }

        let engine = AVAudioEngine()
        self.playbackEngine = engine

        let node = AVAudioPlayerNode()
        self.playerNode = node

        engine.attach(node)
        engine.connect(node, to: engine.outputNode, format: file.processingFormat)

        node.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { _ in }

        do {
            try engine.start()
            node.play()
        } catch {
            printDebug("SpeechRecorder: playback error: \(error)")
        }
    }

    func stopPlaying() {
        playbackEngine?.stop()
        playbackEngine = nil
        playerNode = nil
    }
}
