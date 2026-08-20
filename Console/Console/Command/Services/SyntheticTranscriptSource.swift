import Foundation

/// A single word emitted at a specific delay from the start of listening.
struct TranscriptEntry: Codable {
    let delay: TimeInterval
    let word: String
}

/// Emits pre-scheduled transcript updates for deterministic pipeline testing.
@MainActor
final class SyntheticTranscriptSource: TranscriptSource {

    let requiresPermissions = false

    /// Seconds after last entry before sending isFinal. Nil to never auto-finalize.
    var autoFinalizeDelay: TimeInterval? = 1.5

    private let entries: [TranscriptEntry]
    private var emissionTask: Task<Void, Never>?

    init(entries: [TranscriptEntry]) {
        self.entries = entries
    }

    /// Convenience initializer for concise test construction.
    convenience init(_ pairs: [(TimeInterval, String)]) {
        self.init(entries: pairs.map { TranscriptEntry(delay: $0.0, word: $0.1) })
    }

    func startListening(handler: @escaping (_ transcript: String, _ isFinal: Bool) -> Void) {
        emissionTask?.cancel()

        emissionTask = Task { [entries, autoFinalizeDelay] in
            var cumulative = ""
            var elapsed: TimeInterval = 0

            for entry in entries {
                let delta = max(0, entry.delay - elapsed)
                if delta > 0 {
                    try? await Task.sleep(for: .milliseconds(Int(delta * 1000)))
                }
                guard !Task.isCancelled else { return }

                elapsed = entry.delay
                cumulative += cumulative.isEmpty ? entry.word : " \(entry.word)"
                handler(cumulative, false)
            }

            if let finalizeDelay = autoFinalizeDelay {
                try? await Task.sleep(for: .milliseconds(Int(finalizeDelay * 1000)))
                guard !Task.isCancelled else { return }
                handler(cumulative, true)
            }
        }
    }

    func stopListening() {
        emissionTask?.cancel()
        emissionTask = nil
    }
}
