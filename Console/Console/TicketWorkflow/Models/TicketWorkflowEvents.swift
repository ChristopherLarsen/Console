import Foundation

// MARK: - Execution context (immutable per automated action)

/// Bound to every automated job/action so evidence can be rejected when it
/// belongs to another workflow, step, or obsolete work cycle.
nonisolated struct TicketActionExecutionContext: Equatable, Sendable, Identifiable {
    var id: UUID
    var workflowID: UUID
    var stepID: UUID
    var workCycle: Int
    var workspaceID: UUID
    var checkoutPath: String
    var profileFingerprint: String
    var sourceFingerprint: TicketSourceFingerprint
    var jobID: UUID
    var createdAt: Date
}

/// Bounded fingerprint of a git checkout. Detects HEAD, staged/unstaged, and
/// non-ignored untracked source changes. Incomplete fingerprints must not be
/// treated as current evidence.
nonisolated struct TicketSourceFingerprint: Equatable, Sendable {
    var headOID: String?
    var stagedDigest: String?
    var unstagedDigest: String?
    var untrackedDigest: String?
    var isComplete: Bool
    var capturedAt: Date

    static func incomplete(at date: Date = Date()) -> TicketSourceFingerprint {
        TicketSourceFingerprint(
            headOID: nil,
            stagedDigest: nil,
            unstagedDigest: nil,
            untrackedDigest: nil,
            isComplete: false,
            capturedAt: date
        )
    }
}

nonisolated enum TicketEvidenceApplicability: String, Equatable, Sendable {
    case current
    case staleSource
    case wrongWorkflow
    case wrongStep
    case obsoleteCycle
    case incompleteFingerprint
    case unverified
}

// MARK: - Domain events

/// All mutations enter the reducer as events with stable IDs for dedupe.
nonisolated enum TicketWorkflowEvent: Equatable, Sendable {
    case trackingStarted(TrackingStarted)
    case acknowledgeStep(AcknowledgeStep)
    case skipStep(SkipStep)
    case startStepAction(StartStepAction)
    case applyJobEvidence(ApplyJobEvidence)
    case applyJiraObservation(ApplyJiraObservation)
    case applySessionActivity(ApplySessionActivity)
    case advanceStage(AdvanceStage)
    case returnToImplementation(ReturnToImplementation)
    case setBlocker(SetBlocker)
    case clearBlocker(ClearBlocker)
    case closeWorkflow(CloseWorkflow)
    case markInterrupted(MarkInterrupted)
    case markRevalidationRequired(MarkRevalidationRequired)
    case associateSession(AssociateSession)
    case forgetWorkflow(ForgetWorkflow)
    case attachRuntimeContext(AttachRuntimeContext)

    var eventID: UUID {
        switch self {
        case .trackingStarted(let e): return e.eventID
        case .acknowledgeStep(let e): return e.eventID
        case .skipStep(let e): return e.eventID
        case .startStepAction(let e): return e.eventID
        case .applyJobEvidence(let e): return e.eventID
        case .applyJiraObservation(let e): return e.eventID
        case .applySessionActivity(let e): return e.eventID
        case .advanceStage(let e): return e.eventID
        case .returnToImplementation(let e): return e.eventID
        case .setBlocker(let e): return e.eventID
        case .clearBlocker(let e): return e.eventID
        case .closeWorkflow(let e): return e.eventID
        case .markInterrupted(let e): return e.eventID
        case .markRevalidationRequired(let e): return e.eventID
        case .associateSession(let e): return e.eventID
        case .forgetWorkflow(let e): return e.eventID
        case .attachRuntimeContext(let e): return e.eventID
        }
    }

    var workflowID: UUID {
        switch self {
        case .trackingStarted(let e): return e.workflowID
        case .acknowledgeStep(let e): return e.workflowID
        case .skipStep(let e): return e.workflowID
        case .startStepAction(let e): return e.workflowID
        case .applyJobEvidence(let e): return e.workflowID
        case .applyJiraObservation(let e): return e.workflowID
        case .applySessionActivity(let e): return e.workflowID
        case .advanceStage(let e): return e.workflowID
        case .returnToImplementation(let e): return e.workflowID
        case .setBlocker(let e): return e.workflowID
        case .clearBlocker(let e): return e.workflowID
        case .closeWorkflow(let e): return e.workflowID
        case .markInterrupted(let e): return e.workflowID
        case .markRevalidationRequired(let e): return e.workflowID
        case .associateSession(let e): return e.workflowID
        case .forgetWorkflow(let e): return e.workflowID
        case .attachRuntimeContext(let e): return e.workflowID
        }
    }
}

nonisolated struct TrackingStarted: Equatable, Sendable {
    var eventID: UUID
    var workflowID: UUID
    var association: TicketAssociationToken
    var templateID: UUID
    var templateVersion: Int
    var steps: [TicketChecklistStepState]
    var workspaceID: UUID?
    var at: Date
}

nonisolated struct AcknowledgeStep: Equatable, Sendable {
    var eventID: UUID
    var workflowID: UUID
    var stepID: UUID
    var at: Date
}

nonisolated struct SkipStep: Equatable, Sendable {
    var eventID: UUID
    var workflowID: UUID
    var stepID: UUID
    var at: Date
}

nonisolated struct StartStepAction: Equatable, Sendable {
    var eventID: UUID
    var workflowID: UUID
    var stepID: UUID
    var context: TicketActionExecutionContext
    var at: Date
}

nonisolated struct ApplyJobEvidence: Equatable, Sendable {
    var eventID: UUID
    var workflowID: UUID
    var stepID: UUID
    var workCycle: Int
    var jobID: UUID
    var outcome: TicketStepOutcome
    var sourceFingerprint: TicketSourceFingerprint
    var profileFingerprint: String
    var applicability: TicketEvidenceApplicability
    var at: Date
}

nonisolated struct ApplyJiraObservation: Equatable, Sendable {
    var eventID: UUID
    var workflowID: UUID
    var observation: TicketJiraObservation
    var at: Date
}

nonisolated struct ApplySessionActivity: Equatable, Sendable {
    var eventID: UUID
    var workflowID: UUID
    var sessionID: UUID
    var kind: TicketSessionActivityKind
    var at: Date
}

nonisolated enum TicketSessionActivityKind: String, Equatable, Sendable {
    case sessionCreated
    case turnCompleted
    case sessionEnded
}

nonisolated struct AdvanceStage: Equatable, Sendable {
    var eventID: UUID
    var workflowID: UUID
    var at: Date
}

nonisolated struct ReturnToImplementation: Equatable, Sendable {
    var eventID: UUID
    var workflowID: UUID
    var at: Date
}

nonisolated struct SetBlocker: Equatable, Sendable {
    var eventID: UUID
    var workflowID: UUID
    var code: TicketBlockerCode
    var at: Date
}

nonisolated struct ClearBlocker: Equatable, Sendable {
    var eventID: UUID
    var workflowID: UUID
    var blockerID: UUID
    var at: Date
}

nonisolated struct CloseWorkflow: Equatable, Sendable {
    var eventID: UUID
    var workflowID: UUID
    var observation: TicketJiraObservation
    var at: Date
}

nonisolated struct MarkInterrupted: Equatable, Sendable {
    var eventID: UUID
    var workflowID: UUID
    var stepIDs: [UUID]
    var at: Date
}

nonisolated struct MarkRevalidationRequired: Equatable, Sendable {
    var eventID: UUID
    var workflowID: UUID
    var stepIDs: [UUID]
    var at: Date
}

nonisolated struct AssociateSession: Equatable, Sendable {
    var eventID: UUID
    var workflowID: UUID
    var sessionID: UUID
    var at: Date
}

nonisolated struct ForgetWorkflow: Equatable, Sendable {
    var eventID: UUID
    var workflowID: UUID
    var at: Date
}

/// Memory-only labels/URLs reattached when matching Jira context is rendered.
nonisolated struct AttachRuntimeContext: Equatable, Sendable {
    var eventID: UUID
    var workflowID: UUID
    var displayKey: String
    var displayTitle: String?
    var observedStatus: String?
    var issueURL: URL?
    var navigationGeneration: Int
    var at: Date
}

// MARK: - Reducer result

nonisolated enum TicketWorkflowReduceError: Equatable, Sendable {
    case unknownWorkflow
    case duplicateEvent
    case wrongWorkflow
    case stepNotFound
    case stepNotManual
    case stepNotOptional
    case requiredGatesUnsatisfied
    case automatedCannotAcknowledge
    case evidenceNotApplicable
    case observationRejected(TicketJiraObservationRejection)
    case alreadyClosed
    case lifecycleBlocked
}

nonisolated struct TicketWorkflowReduceResult: Equatable, Sendable {
    var record: TicketWorkflowRecord?
    var removedWorkflowID: UUID?
    var error: TicketWorkflowReduceError?
}
