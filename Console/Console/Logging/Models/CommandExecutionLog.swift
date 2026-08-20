import Foundation

// Outcome of a voice-triggered command execution
enum CommandLogResult: String, Codable {
    case success
    case failed
    case noMatch
    case cancelled
}

enum CommandType: String, Codable {
    case user
    case console
}

struct CommandExecutionLog: Codable, Identifiable {
    let id: UUID
    let commandType: CommandType
    let timestamp: Date
    let triggerWord: String
    let rawTranscript: String
    let strippedTranscript: String
    let matchedCommand: String?
    let matchConfidence: Double?
    let executionResult: CommandLogResult
    let executionDuration: TimeInterval?
    let errorMessage: String?

    var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: timestamp)
    }

    var confidencePercentage: String {
        guard let confidence = matchConfidence else { return "N/A" }
        return "\(Int(confidence * 100))%"
    }

    // Emoji indicator for quick visual scanning in logs
    var statusEmoji: String {
        switch executionResult {
        case .success: return "✅"
        case .failed: return "❌"
        case .noMatch: return "⚠️"
        case .cancelled: return "🚫"
        }
    }

    var statusLabel: String {
        switch executionResult {
        case .success: return "Success"
        case .failed: return "Failed"
        case .noMatch: return "No Match"
        case .cancelled: return "Cancelled"
        }
    }

    // Formatted execution duration for display
    var formattedDuration: String {
        guard let duration = executionDuration else { return "N/A" }
        return String(format: "%.1fs", duration)
    }
}
