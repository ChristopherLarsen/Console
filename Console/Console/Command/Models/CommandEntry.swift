import Foundation
import SwiftUI

@Observable
class CommandEntry: Identifiable {
    let id = UUID()
    let inputText: String
    let toolName: String
    var status: CommandStatus = .waiting
    var resultMessage: String?
    let createdAt = Date()

    init(inputText: String, toolName: String = "pending") {
        self.inputText = inputText
        self.toolName = toolName
    }
}

/// Execution status of a command entry.
enum CommandStatus: String, CaseIterable {
    case waiting
    case executing
    case completed
    case failed

    var displayLabel: String {
        switch self {
        case .waiting: return "Waiting"
        case .executing: return "Executing"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }

    var indicatorColor: Color {
        switch self {
        case .waiting: return .gray
        case .executing: return Color.blue
        case .completed: return .green
        case .failed: return .red
        }
    }

    var indicatorIcon: String {
        switch self {
        case .waiting: return "circle"
        case .executing: return "circle.dotted"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    var isInProgress: Bool {
        self == .waiting || self == .executing
    }
}
