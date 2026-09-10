import Foundation

/// Reduced lifecycle events after hook filtering and MCP validation.
/// Raw hook payloads never reach this layer.
enum SessionLifecycleEvent: Equatable, Sendable {
    case sessionStarted
    case promptSubmitted
    case permissionRequested
    case questionAsked
    case turnCompleted
    case turnFailed
    case cwdChanged(String)
    case sessionEnded
    case processTerminated
    /// Deliberate agent message via the Console MCP tools.
    case attentionReported(BridgeAttentionCategory, message: String?)
    case artifactLinked(SessionArtifact)
    case completionReported(BridgeCompletionOutcome, summary: String)
    /// Optimistic: the user typed or submitted terminal input.
    case userInputObserved
}

enum BridgeAttentionCategory: String, Codable, Sendable {
    case permission
    case question
    case blocked
    case needsReview = "needs_review"
}

enum BridgeCompletionOutcome: String, Codable, Sendable {
    case completed
    case blocked
    case needsReview = "needs_review"
}

/// Value-type state slice the reducer operates on.
struct SessionLifecycleState: Equatable, Sendable {
    var activity: SessionActivity = .starting
    var attention: SessionAttention = .none
    var summary: String?
    var workingDirectoryPath: String?

    var displayedState: DisplayedSessionState {
        displayedSessionState(activity: activity, attention: attention)
    }

    mutating func apply(_ event: SessionLifecycleEvent) {
        // Exit suppresses async hook reordering: a late prompt/turn/completion
        // after `sessionEnded` must not fake liveness for a dead row. A fresh
        // `sessionStarted` is the opposite signal — a live Claude conversation
        // exists in this terminal again (an in-session `/resume`, or any
        // restart of an instrumented Claude in the same PTY), so tracking
        // restarts from a clean slate instead of staying frozen at Exited.
        if activity == .exited {
            switch event {
            case .sessionStarted:
                activity = .idle
                attention = .none
                summary = nil
            case .sessionEnded, .processTerminated:
                activity = .exited
            default:
                break
            }
            return
        }

        switch event {
        case .sessionStarted:
            activity = .idle

        case .promptSubmitted:
            activity = .working
            if attention == .unreadCompletion {
                attention = .none
            }
            summary = nil
            clearTransientAttention()

        case .permissionRequested:
            attention = .permission

        case .questionAsked:
            attention = .question

        case .turnCompleted:
            activity = .idle
            if attention == .none || attention == .unreadCompletion {
                attention = .unreadCompletion
            }

        case .turnFailed:
            activity = .error

        case .cwdChanged(let newPath):
            workingDirectoryPath = newPath

        case .sessionEnded, .processTerminated:
            activity = .exited

        case .attentionReported(let category, let message):
            switch category {
            case .permission:
                attention = .permission
            case .question:
                attention = .question
            case .blocked:
                attention = .blocked
            case .needsReview:
                attention = .needsReview
            }
            if let message, !message.isEmpty {
                summary = message
            }

        case .artifactLinked:
            // Applied by the store (needs list mutation); nothing here.
            break

        case .completionReported(let outcome, let summaryText):
            summary = summaryText
            switch outcome {
            case .completed:
                if attention == .none || attention == .unreadCompletion {
                    attention = .unreadCompletion
                }
            case .blocked:
                attention = .blocked
            case .needsReview:
                attention = .needsReview
            }

        case .userInputObserved:
            clearTransientAttention()
        }
    }

    /// Permission/question attention is optimistic and clears on user input.
    private mutating func clearTransientAttention() {
        if attention == .permission || attention == .question {
            attention = .none
        }
    }
}
