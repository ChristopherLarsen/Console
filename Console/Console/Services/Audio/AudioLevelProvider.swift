import Foundation


@MainActor @Observable
final class AudioLevelProvider {
    static let shared = AudioLevelProvider()
    var audioLevel: Float = 0.0
    private init() {}
}
