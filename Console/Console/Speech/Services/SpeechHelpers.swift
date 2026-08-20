import Foundation
import AVFoundation

extension SpeechStory: Equatable {
    static func == (lhs: SpeechStory, rhs: SpeechStory) -> Bool {
        lhs.id == rhs.id
    }
}

extension SpeechStory: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum TranscriptionState {
    case transcribing
    case notTranscribing
}

public enum TranscriptionError: Error {
    case couldNotDownloadModel
    case failedToSetupRecognitionStream
    case invalidAudioDataType
    case localeNotSupported
    case noInternetForModelDownload
    case audioFilePathNotFound
    
    var descriptionString: String {
        switch self {
        case .couldNotDownloadModel:
            return "Could not download the model."
        case .failedToSetupRecognitionStream:
            return "Could not set up the speech recognition stream."
        case .invalidAudioDataType:
            return "Unsupported audio format."
        case .localeNotSupported:
            return "This locale is not yet supported by SpeechAnalyzer."
        case .noInternetForModelDownload:
            return "The model could not be downloaded because the user is not connected to internet."
        case .audioFilePathNotFound:
            return "Couldn't write audio to file."
        }
    }
}

public enum RecordingState: Equatable {
    case stopped
    case recording
    case paused
}

public enum PlaybackState: Equatable {
    case playing
    case notPlaying
}

public struct AudioData: @unchecked Sendable {
    var buffer: AVAudioPCMBuffer
    var time: AVAudioTime
}

@available(macOS 26.0, *)
extension SpeechRecorder {
    func isAuthorized() async -> Bool {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            return true
        }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }
    
    func writeBufferToDisk(buffer: AVAudioPCMBuffer) {
        do {
            try self.file?.write(from: buffer)
        } catch {
            printDebug("SpeechRecorder: file writing error: \(error)")
        }
    }
}

extension AVAudioPlayerNode {
    var speechCurrentTime: TimeInterval {
        guard let nodeTime = self.lastRenderTime,
              let playerTime = self.playerTime(forNodeTime: nodeTime) else { return 0 }
        return Double(playerTime.sampleTime) / playerTime.sampleRate
    }
}
