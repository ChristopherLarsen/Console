import Foundation

/// Abstraction over speech-to-text engines, enabling synthetic sources for testing.
@MainActor
protocol TranscriptSource {

    /// Begin producing transcript updates. Handler receives cumulative transcript
    /// text and an isFinal flag mirroring SFSpeechRecognitionResult behavior.
    func startListening(handler: @escaping (_ transcript: String, _ isFinal: Bool) -> Void)

    /// Stop producing transcript updates and release resources.
    func stopListening()

    /// Whether the source needs microphone and speech recognition permissions.
    var requiresPermissions: Bool { get }
}
