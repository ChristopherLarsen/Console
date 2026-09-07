import Foundation
import SwiftTerm

/// Lifecycle activity for a Console Claude session.
enum SessionActivity: String, Codable, Sendable, Equatable {
    case starting
    case idle
    case working
    case exited
    case error
    case unknown
}

/// Attention flag that rides alongside activity without being overwritten by it.
enum SessionAttention: String, Codable, Sendable, Equatable {
    case none
    case unreadCompletion
    case permission
    case question
    case blocked
    case needsReview
}

enum SessionArtifactKind: String, Codable, Sendable, Equatable {
    case jiraIssue = "jira_issue"
    case gitlabMergeRequest = "gitlab_merge_request"
}

/// An informational artifact chip produced by the agent. Never fetched.
struct SessionArtifact: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: SessionArtifactKind
    let label: String
    let url: URL?

    init(kind: SessionArtifactKind, label: String, url: URL? = nil) {
        self.id = UUID()
        self.kind = kind
        self.label = label
        self.url = url
    }
}

/// Health of the bridge instrumentation channel for one session.
enum BridgeStatus: String, Codable, Sendable, Equatable {
    case unknown
    case active
    case unavailable
}

/// One concurrent Claude Code terminal session.
struct ConsoleSession: Identifiable, Equatable {
    let id: UUID
    let claudeSessionID: UUID
    var name: String
    var workingDirectory: URL
    let terminalView: LocalProcessTerminalView
    var activity: SessionActivity
    var attention: SessionAttention
    var summary: String?
    var artifacts: [SessionArtifact]
    var bridgeStatus: BridgeStatus
    /// Why the session exists; nil for sessions created before intents.
    var purpose: SessionPurpose?
    /// Set when the session launched without a usable plugin/bridge.
    /// Display-only; never implies the Claude process failed to start.
    var instrumentationWarning: String?

    init(
        id: UUID,
        claudeSessionID: UUID,
        name: String,
        workingDirectory: URL,
        terminalView: LocalProcessTerminalView,
        activity: SessionActivity,
        attention: SessionAttention,
        summary: String?,
        artifacts: [SessionArtifact],
        bridgeStatus: BridgeStatus,
        purpose: SessionPurpose? = nil,
        instrumentationWarning: String? = nil
    ) {
        self.id = id
        self.claudeSessionID = claudeSessionID
        self.name = name
        self.workingDirectory = workingDirectory
        self.terminalView = terminalView
        self.activity = activity
        self.attention = attention
        self.summary = summary
        self.artifacts = artifacts
        self.bridgeStatus = bridgeStatus
        self.purpose = purpose
        self.instrumentationWarning = instrumentationWarning
    }
}

/// The single user-facing state shown for a row/header.
enum DisplayedSessionState: String, Sendable, Equatable {
    case needsApproval
    case needsInput
    case blocked
    case needsReview
    case error
    case done
    case working
    case idle
    case starting
    case exited
    case unknown

    var label: String {
        switch self {
        case .needsApproval: return "Needs Approval"
        case .needsInput: return "Needs Input"
        case .blocked: return "Blocked"
        case .needsReview: return "Needs Review"
        case .error: return "Error"
        case .done: return "Done"
        case .working: return "Working"
        case .idle: return "Idle"
        case .starting: return "Starting"
        case .exited: return "Exited"
        case .unknown: return "Unknown"
        }
    }

    /// Lower sorts earlier in the displayed-state priority list from
    /// CONSOLE_TERM_COMM.md §2.
    var priorityRank: Int {
        switch self {
        case .needsApproval, .needsInput: return 0
        case .blocked, .needsReview: return 1
        case .error: return 2
        case .done: return 3
        case .working: return 4
        case .idle: return 5
        case .starting: return 6
        case .exited: return 7
        case .unknown: return 8
        }
    }

    static func < (lhs: DisplayedSessionState, rhs: DisplayedSessionState) -> Bool {
        lhs.priorityRank < rhs.priorityRank
    }
}

/// Resolves the displayed state from independent activity and attention values.
/// Exit wins over lingering attention: a dead session never presents as
/// needs-you (the attention flag itself is kept for diagnostics only).
func displayedSessionState(activity: SessionActivity, attention: SessionAttention) -> DisplayedSessionState {
    if activity == .exited {
        return .exited
    }

    switch attention {
    case .permission: return .needsApproval
    case .question: return .needsInput
    case .blocked: return .blocked
    case .needsReview: return .needsReview
    case .unreadCompletion, .none:
        break
    }

    switch activity {
    case .error:
        return .error
    case .idle:
        return attention == .unreadCompletion ? .done : .idle
    case .working:
        return .working
    case .starting:
        return .starting
    case .exited:
        return .exited
    case .unknown:
        return .unknown
    }
}
