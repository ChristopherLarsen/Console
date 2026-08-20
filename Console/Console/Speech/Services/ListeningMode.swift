import AVFoundation

/// Priority levels for listening modes, higher priority preempts lower.
enum ModePriority: Int, Comparable {
    case background = 0
    case normal = 1
    case primary = 2
    case exclusive = 3

    static func < (lhs: ModePriority, rhs: ModePriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Defines a listening mode that can be activated by AudioSessionController.
@MainActor protocol ListeningMode: AnyObject {
    var modeIdentifier: String { get }
    var priority: ModePriority { get }
    var isActive: Bool { get }

    /// Called when this mode becomes active — begin processing audio.
    func activate(audioStream: AsyncStream<AVAudioPCMBuffer>?) async

    /// Called when mode is being deactivated — clean up and stop.
    func deactivate() async
}
