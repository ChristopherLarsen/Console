import Foundation

// MARK: - Stages (fixed order)

/// The seven fixed Ticket Work stages. Order is immutable; templates cannot
/// insert, remove, or reorder stages.
nonisolated enum TicketWorkflowStage: String, Codable, Equatable, Sendable, CaseIterable {
    case understand
    case prepare
    case implement
    case verify
    case review
    case deliver
    case close

    var sortIndex: Int {
        switch self {
        case .understand: return 0
        case .prepare: return 1
        case .implement: return 2
        case .verify: return 3
        case .review: return 4
        case .deliver: return 5
        case .close: return 6
        }
    }

    var displayName: String {
        switch self {
        case .understand: return "Understand"
        case .prepare: return "Prepare"
        case .implement: return "Implement"
        case .verify: return "Verify"
        case .review: return "Review"
        case .deliver: return "Deliver"
        case .close: return "Close"
        }
    }

    var next: TicketWorkflowStage? {
        Self.allCases.first { $0.sortIndex == sortIndex + 1 }
    }
}

// MARK: - Step kinds & completion sources

/// How a checklist step becomes satisfied. Automated sources cannot be
/// marked successful by acknowledgement alone.
nonisolated enum TicketStepCompletionSource: String, Codable, Equatable, Sendable {
    case developerAcknowledgement
    case localAvailabilityCheck
    case sessionActivity
    case jobResult
    case jiraObservation
    case composite
}

/// Built-in step roles used by advancement, invalidation, and Next targeting.
/// Templates may add generic custom steps; protected roles cannot be removed.
nonisolated enum TicketStepRole: String, Codable, Equatable, Sendable {
    case scopeUnderstood
    case acceptanceUnderstood
    case workspaceSelected
    case branchPrepared
    case implementationCompleted
    case sessionsVisible
    case buildPassed
    case testsPassed
    case selfReviewCompleted
    case manualDeviceCheck
    case mrPrepared
    case feedbackAddressed
    case reviewApprovalConfirmed
    case mergeConfirmed
    case qaCompleted
    case releaseRequirementsSatisfied
    case documentationCleanup
    case jiraClosureVerified
    case custom
}

nonisolated enum TicketStepOutcome: String, Codable, Equatable, Sendable {
    case pending
    case skipped
    case acknowledged
    case running
    case succeeded
    case failed
    case interrupted
    case previouslyPassedNeedsRevalidation
    case blocked
    case unverified
}

nonisolated enum TicketBlockerCode: String, Codable, Equatable, Sendable {
    case waitingForInformation
    case waitingForReviewer
    case waitingForQA
    case waitingForExternalAction
    case workspaceRepairNeeded
}

nonisolated enum TicketWorkflowFilter: String, Codable, Equatable, Sendable {
    case active
    case closed
}

/// High-level workflow lifecycle separate from Jira status.
nonisolated enum TicketWorkflowLifecycle: String, Codable, Equatable, Sendable {
    case active
    case blocked
    case closed
    case needsReconciliation
}

// MARK: - Template

nonisolated struct TicketChecklistStepTemplate: Equatable, Sendable, Identifiable, Codable {
    var id: UUID
    var stage: TicketWorkflowStage
    var role: TicketStepRole
    var title: String
    var isRequired: Bool
    var completionSource: TicketStepCompletionSource
    /// When true, template editor cannot remove this step.
    var isProtected: Bool

    init(
        id: UUID = UUID(),
        stage: TicketWorkflowStage,
        role: TicketStepRole,
        title: String,
        isRequired: Bool,
        completionSource: TicketStepCompletionSource,
        isProtected: Bool = false
    ) {
        self.id = id
        self.stage = stage
        self.role = role
        self.title = title
        self.isRequired = isRequired
        self.completionSource = completionSource
        self.isProtected = isProtected
    }
}

nonisolated struct TicketWorkflowTemplate: Equatable, Sendable, Identifiable, Codable {
    var id: UUID
    var version: Int
    var displayName: String
    var steps: [TicketChecklistStepTemplate]
    /// Exact terminal Jira status label after whitespace/case normalization.
    var terminalJiraStatus: String

    static let defaultTerminalJiraStatus = "Closed"

    static func normalizeStatus(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

// MARK: - Runtime step / workflow state (in-memory domain)

nonisolated struct TicketChecklistStepState: Equatable, Sendable, Identifiable, Codable {
    var id: UUID
    var templateStepID: UUID
    var stage: TicketWorkflowStage
    var role: TicketStepRole
    var title: String
    var isRequired: Bool
    var completionSource: TicketStepCompletionSource
    var isProtected: Bool
    var outcome: TicketStepOutcome
    var updatedAt: Date?
    /// Work cycle that last satisfied this step; used for invalidation.
    var satisfiedInCycle: Int?

    init(from template: TicketChecklistStepTemplate, outcome: TicketStepOutcome = .pending) {
        self.id = UUID()
        self.templateStepID = template.id
        self.stage = template.stage
        self.role = template.role
        self.title = template.title
        self.isRequired = template.isRequired
        self.completionSource = template.completionSource
        self.isProtected = template.isProtected
        self.outcome = outcome
        self.updatedAt = nil
        self.satisfiedInCycle = nil
    }
}

nonisolated struct TicketWorkflowBlocker: Equatable, Sendable, Identifiable, Codable {
    var id: UUID
    var code: TicketBlockerCode
    var createdAt: Date
    var clearedAt: Date?

    var isActive: Bool { clearedAt == nil }
}

nonisolated struct TicketAssociatedSession: Equatable, Sendable, Identifiable, Codable {
    var id: UUID
    var sessionID: UUID
    var associatedAt: Date
}

/// Opaque HMAC-based association. Never contains issue key or URL plaintext.
nonisolated struct TicketAssociationToken: Equatable, Sendable, Hashable, Codable {
    /// Domain-separated HMAC digest (hex or raw Data encoded in storage DTO).
    var digest: Data
}

nonisolated struct TicketWorkflowRecord: Equatable, Sendable, Identifiable {
    var id: UUID
    var association: TicketAssociationToken
    var templateID: UUID
    var templateVersion: Int
    var lifecycle: TicketWorkflowLifecycle
    var currentStage: TicketWorkflowStage
    var workCycle: Int
    var steps: [TicketChecklistStepState]
    var blockers: [TicketWorkflowBlocker]
    var associatedSessionIDs: [TicketAssociatedSession]
    var workspaceID: UUID?
    var createdAt: Date
    var updatedAt: Date
    var closedAt: Date?
    /// Bounded generic transition history (codes only).
    var transitionHistory: [TicketWorkflowTransition]
}

nonisolated struct TicketWorkflowTransition: Equatable, Sendable, Codable {
    var id: UUID
    var at: Date
    var code: TicketWorkflowTransitionCode
    var stage: TicketWorkflowStage?
    var stepID: UUID?
    var workCycle: Int
}

nonisolated enum TicketWorkflowTransitionCode: String, Codable, Equatable, Sendable {
    case trackingStarted
    case stepAcknowledged
    case stepSkipped
    case stepActionStarted
    case stepSucceeded
    case stepFailed
    case stepInterrupted
    case evidenceApplied
    case evidenceRejected
    case stageAdvanced
    case returnedToImplementation
    case blocked
    case resumed
    case closed
    case reconciliationNeeded
    case forgotten
}
