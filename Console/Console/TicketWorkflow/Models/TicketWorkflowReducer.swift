import Foundation

/// Pure reducer surface. Package A owns the implementation and tests.
/// Views and coordinators must not duplicate advancement rules.
enum TicketWorkflowReducer {
    static let maxTransitionHistory = 64

    /// Roles invalidated when returning to implementation / starting a new cycle.
    static let codeDependentRoles: Set<TicketStepRole> = [
        .buildPassed,
        .testsPassed,
        .selfReviewCompleted,
        .manualDeviceCheck,
        .reviewApprovalConfirmed,
        .mergeConfirmed,
        .qaCompleted,
        .releaseRequirementsSatisfied,
        .jiraClosureVerified,
    ]

    /// Roles that cannot be satisfied by developer acknowledgement alone.
    static let automatedOnlyRoles: Set<TicketStepRole> = [
        .buildPassed,
        .testsPassed,
        .jiraClosureVerified,
    ]

    /// Apply one event to the workflow map. Returns the updated record, an
    /// optional removal, or a typed error. Duplicate `eventID`s are no-ops
    /// that report `.duplicateEvent` without mutating state.
    static func reduce(
        workflows: inout [UUID: TicketWorkflowRecord],
        seenEventIDs: inout Set<UUID>,
        event: TicketWorkflowEvent,
        terminalJiraStatus: String = TicketWorkflowTemplate.defaultTerminalJiraStatus,
        now: Date = Date()
    ) -> TicketWorkflowReduceResult {
        if seenEventIDs.contains(event.eventID) {
            return TicketWorkflowReduceResult(
                record: workflows[event.workflowID],
                removedWorkflowID: nil,
                error: .duplicateEvent
            )
        }
        seenEventIDs.insert(event.eventID)

        switch event {
        case .trackingStarted(let payload):
            return trackingStarted(workflows: &workflows, payload: payload, now: now)

        case .forgetWorkflow(let payload):
            return forgetWorkflow(workflows: &workflows, payload: payload)

        case .attachRuntimeContext(let payload):
            // Memory-only; durable record is unchanged. Store/presentation holds labels.
            guard let record = workflows[payload.workflowID] else {
                return result(error: .unknownWorkflow)
            }
            return result(record: record)

        case .acknowledgeStep(let payload):
            return mutate(workflows: &workflows, id: payload.workflowID) { record in
                try acknowledge(record: &record, stepID: payload.stepID, at: payload.at, now: now)
            }

        case .skipStep(let payload):
            return mutate(workflows: &workflows, id: payload.workflowID) { record in
                try skip(record: &record, stepID: payload.stepID, at: payload.at, now: now)
            }

        case .startStepAction(let payload):
            return mutate(workflows: &workflows, id: payload.workflowID) { record in
                try startAction(record: &record, payload: payload, now: now)
            }

        case .applyJobEvidence(let payload):
            return mutate(workflows: &workflows, id: payload.workflowID) { record in
                try applyJobEvidence(record: &record, payload: payload, now: now)
            }

        case .applyJiraObservation(let payload):
            return mutate(workflows: &workflows, id: payload.workflowID) { record in
                try applyJiraObservation(
                    record: &record,
                    payload: payload,
                    terminalJiraStatus: terminalJiraStatus,
                    now: now
                )
            }

        case .applySessionActivity(let payload):
            return mutate(workflows: &workflows, id: payload.workflowID) { record in
                try applySessionActivity(record: &record, payload: payload, now: now)
            }

        case .advanceStage(let payload):
            return mutate(workflows: &workflows, id: payload.workflowID) { record in
                try advanceStage(record: &record, at: payload.at, now: now)
            }

        case .returnToImplementation(let payload):
            return mutate(workflows: &workflows, id: payload.workflowID) { record in
                try returnToImplementation(record: &record, at: payload.at, now: now)
            }

        case .setBlocker(let payload):
            return mutate(workflows: &workflows, id: payload.workflowID) { record in
                try setBlocker(record: &record, payload: payload, now: now)
            }

        case .clearBlocker(let payload):
            return mutate(workflows: &workflows, id: payload.workflowID) { record in
                try clearBlocker(record: &record, payload: payload, now: now)
            }

        case .closeWorkflow(let payload):
            return mutate(workflows: &workflows, id: payload.workflowID) { record in
                try closeWorkflow(
                    record: &record,
                    payload: payload,
                    terminalJiraStatus: terminalJiraStatus,
                    now: now
                )
            }

        case .markInterrupted(let payload):
            return mutate(workflows: &workflows, id: payload.workflowID) { record in
                markInterrupted(record: &record, payload: payload, now: now)
            }

        case .markRevalidationRequired(let payload):
            return mutate(workflows: &workflows, id: payload.workflowID) { record in
                markRevalidationRequired(record: &record, payload: payload, now: now)
            }

        case .associateSession(let payload):
            return mutate(workflows: &workflows, id: payload.workflowID) { record in
                associateSession(record: &record, payload: payload, now: now)
            }
        }
    }

    // MARK: - Satisfaction helpers (shared with presentation)

    static func isSatisfied(_ step: TicketChecklistStepState) -> Bool {
        switch step.outcome {
        case .succeeded, .acknowledged:
            return true
        case .skipped:
            return !step.isRequired
        case .pending, .running, .failed, .interrupted,
             .previouslyPassedNeedsRevalidation, .blocked, .unverified:
            return false
        }
    }

    static func requiredStepsSatisfied(in record: TicketWorkflowRecord, stage: TicketWorkflowStage) -> Bool {
        record.steps
            .filter { $0.stage == stage && $0.isRequired }
            .allSatisfy(isSatisfied)
    }

    static func allRequiredInternalGatesSatisfied(_ record: TicketWorkflowRecord) -> Bool {
        record.steps
            .filter { $0.isRequired && $0.role != .jiraClosureVerified }
            .allSatisfy(isSatisfied)
    }

    static func canAdvance(_ record: TicketWorkflowRecord) -> Bool {
        guard record.lifecycle == .active || record.lifecycle == .needsReconciliation else {
            return false
        }
        guard record.currentStage.next != nil else { return false }
        return requiredStepsSatisfied(in: record, stage: record.currentStage)
    }

    static func canClose(
        _ record: TicketWorkflowRecord,
        observation: TicketJiraObservation?,
        terminalJiraStatus: String,
        now: Date
    ) -> (Bool, TicketJiraObservationRejection?) {
        guard record.lifecycle != .closed else {
            return (false, nil)
        }
        guard record.lifecycle != .blocked else {
            return (false, nil)
        }
        guard allRequiredInternalGatesSatisfied(record) else {
            return (false, nil)
        }
        guard let observation else {
            return (false, .missingAssociation)
        }
        switch TicketJiraClosureDecision.evaluate(
            observation: observation,
            expectedAssociation: record.association,
            terminalStatus: terminalJiraStatus,
            now: now
        ) {
        case .accepted:
            return (true, nil)
        case .rejected(let reason):
            return (false, reason)
        }
    }

    // MARK: - Event handlers

    private static func trackingStarted(
        workflows: inout [UUID: TicketWorkflowRecord],
        payload: TrackingStarted,
        now: Date
    ) -> TicketWorkflowReduceResult {
        if let existing = workflows.values.first(where: { $0.association == payload.association }) {
            return result(record: existing)
        }
        if let existing = workflows[payload.workflowID] {
            return result(record: existing)
        }

        var record = TicketWorkflowRecord(
            id: payload.workflowID,
            association: payload.association,
            templateID: payload.templateID,
            templateVersion: payload.templateVersion,
            lifecycle: .active,
            currentStage: .understand,
            workCycle: 1,
            steps: payload.steps,
            blockers: [],
            associatedSessionIDs: [],
            workspaceID: payload.workspaceID,
            createdAt: payload.at,
            updatedAt: payload.at,
            closedAt: nil,
            transitionHistory: []
        )
        appendTransition(
            &record,
            code: .trackingStarted,
            at: payload.at,
            stage: .understand,
            stepID: nil,
            now: now
        )
        workflows[record.id] = record
        return result(record: record)
    }

    private static func forgetWorkflow(
        workflows: inout [UUID: TicketWorkflowRecord],
        payload: ForgetWorkflow
    ) -> TicketWorkflowReduceResult {
        guard workflows.removeValue(forKey: payload.workflowID) != nil else {
            return result(error: .unknownWorkflow)
        }
        return TicketWorkflowReduceResult(
            record: nil,
            removedWorkflowID: payload.workflowID,
            error: nil
        )
    }

    private static func acknowledge(
        record: inout TicketWorkflowRecord,
        stepID: UUID,
        at: Date,
        now: Date
    ) throws {
        try ensureMutableLifecycle(record)
        guard let index = record.steps.firstIndex(where: { $0.id == stepID }) else {
            throw ReduceFailure.stepNotFound
        }
        var step = record.steps[index]
        if Self.automatedOnlyRoles.contains(step.role) {
            throw ReduceFailure.automatedCannotAcknowledge
        }
        guard step.completionSource == .developerAcknowledgement
            || step.completionSource == .composite
        else {
            throw ReduceFailure.stepNotManual
        }
        step.outcome = .acknowledged
        step.updatedAt = at
        step.satisfiedInCycle = record.workCycle
        record.steps[index] = step
        record.updatedAt = at
        appendTransition(
            &record,
            code: .stepAcknowledged,
            at: at,
            stage: step.stage,
            stepID: step.id,
            now: now
        )
    }

    private static func skip(
        record: inout TicketWorkflowRecord,
        stepID: UUID,
        at: Date,
        now: Date
    ) throws {
        try ensureMutableLifecycle(record)
        guard let index = record.steps.firstIndex(where: { $0.id == stepID }) else {
            throw ReduceFailure.stepNotFound
        }
        var step = record.steps[index]
        guard !step.isRequired else {
            throw ReduceFailure.stepNotOptional
        }
        step.outcome = .skipped
        step.updatedAt = at
        step.satisfiedInCycle = record.workCycle
        record.steps[index] = step
        record.updatedAt = at
        appendTransition(
            &record,
            code: .stepSkipped,
            at: at,
            stage: step.stage,
            stepID: step.id,
            now: now
        )
    }

    private static func startAction(
        record: inout TicketWorkflowRecord,
        payload: StartStepAction,
        now: Date
    ) throws {
        try ensureMutableLifecycle(record)
        guard payload.context.workflowID == record.id else {
            throw ReduceFailure.wrongWorkflow
        }
        guard payload.context.workCycle == record.workCycle else {
            throw ReduceFailure.evidenceNotApplicable
        }
        guard let index = record.steps.firstIndex(where: { $0.id == payload.stepID }) else {
            throw ReduceFailure.stepNotFound
        }
        guard payload.context.stepID == payload.stepID else {
            throw ReduceFailure.evidenceNotApplicable
        }
        var step = record.steps[index]
        step.outcome = .running
        step.updatedAt = payload.at
        record.steps[index] = step
        record.updatedAt = payload.at
        appendTransition(
            &record,
            code: .stepActionStarted,
            at: payload.at,
            stage: step.stage,
            stepID: step.id,
            now: now
        )
    }

    private static func applyJobEvidence(
        record: inout TicketWorkflowRecord,
        payload: ApplyJobEvidence,
        now: Date
    ) throws {
        try ensureMutableLifecycle(record)
        guard payload.workflowID == record.id else {
            throw ReduceFailure.wrongWorkflow
        }
        guard let index = record.steps.firstIndex(where: { $0.id == payload.stepID }) else {
            throw ReduceFailure.stepNotFound
        }

        switch payload.applicability {
        case .wrongWorkflow:
            appendTransition(
                &record,
                code: .evidenceRejected,
                at: payload.at,
                stage: record.steps[index].stage,
                stepID: payload.stepID,
                now: now
            )
            throw ReduceFailure.wrongWorkflow
        case .wrongStep:
            appendTransition(
                &record,
                code: .evidenceRejected,
                at: payload.at,
                stage: record.steps[index].stage,
                stepID: payload.stepID,
                now: now
            )
            throw ReduceFailure.evidenceNotApplicable
        case .obsoleteCycle:
            appendTransition(
                &record,
                code: .evidenceRejected,
                at: payload.at,
                stage: record.steps[index].stage,
                stepID: payload.stepID,
                now: now
            )
            throw ReduceFailure.evidenceNotApplicable
        case .current, .staleSource, .incompleteFingerprint, .unverified:
            break
        }

        if payload.workCycle != record.workCycle {
            appendTransition(
                &record,
                code: .evidenceRejected,
                at: payload.at,
                stage: record.steps[index].stage,
                stepID: payload.stepID,
                now: now
            )
            throw ReduceFailure.evidenceNotApplicable
        }

        var appliedOutcome = payload.outcome
        if payload.applicability != .current {
            if appliedOutcome == .succeeded {
                appliedOutcome = .unverified
            }
            // Failed/unverified/running from the event stay as provided.
        }

        var step = record.steps[index]
        step.outcome = appliedOutcome
        step.updatedAt = payload.at
        if appliedOutcome == .succeeded {
            step.satisfiedInCycle = record.workCycle
        } else {
            step.satisfiedInCycle = nil
        }
        record.steps[index] = step
        record.updatedAt = payload.at

        let code: TicketWorkflowTransitionCode
        switch appliedOutcome {
        case .succeeded:
            code = .stepSucceeded
        case .failed:
            code = .stepFailed
        default:
            code = .evidenceApplied
        }
        appendTransition(
            &record,
            code: code,
            at: payload.at,
            stage: step.stage,
            stepID: step.id,
            now: now
        )
    }

    private static func applyJiraObservation(
        record: inout TicketWorkflowRecord,
        payload: ApplyJiraObservation,
        terminalJiraStatus: String,
        now: Date
    ) throws {
        try ensureMutableLifecycle(record)
        guard let index = record.steps.firstIndex(where: { $0.role == .jiraClosureVerified }) else {
            throw ReduceFailure.stepNotFound
        }

        let decision = TicketJiraClosureDecision.evaluate(
            observation: payload.observation,
            expectedAssociation: record.association,
            terminalStatus: terminalJiraStatus,
            now: now
        )

        var step = record.steps[index]
        switch decision {
        case .accepted:
            step.outcome = .succeeded
            step.satisfiedInCycle = record.workCycle
            appendTransition(
                &record,
                code: .stepSucceeded,
                at: payload.at,
                stage: step.stage,
                stepID: step.id,
                now: now
            )
        case .rejected:
            step.outcome = .unverified
            step.satisfiedInCycle = nil
            appendTransition(
                &record,
                code: .evidenceRejected,
                at: payload.at,
                stage: step.stage,
                stepID: step.id,
                now: now
            )
        }
        step.updatedAt = payload.at
        record.steps[index] = step
        record.updatedAt = payload.at

        if case .rejected(let reason) = decision {
            throw ReduceFailure.observationRejected(reason)
        }
    }

    private static func applySessionActivity(
        record: inout TicketWorkflowRecord,
        payload: ApplySessionActivity,
        now: Date
    ) throws {
        try ensureMutableLifecycle(record)
        // Supporting activity only — never completes build/tests/review/closure.
        guard let index = record.steps.firstIndex(where: {
            $0.role == .sessionsVisible && $0.completionSource == .sessionActivity
        }) else {
            record.updatedAt = payload.at
            return
        }
        var step = record.steps[index]
        switch payload.kind {
        case .sessionCreated, .turnCompleted, .sessionEnded:
            if step.outcome != .succeeded && step.outcome != .acknowledged {
                step.outcome = .succeeded
                step.updatedAt = payload.at
                step.satisfiedInCycle = record.workCycle
                record.steps[index] = step
                appendTransition(
                    &record,
                    code: .evidenceApplied,
                    at: payload.at,
                    stage: step.stage,
                    stepID: step.id,
                    now: now
                )
            }
        }
        if !record.associatedSessionIDs.contains(where: { $0.sessionID == payload.sessionID }) {
            record.associatedSessionIDs.append(
                TicketAssociatedSession(id: UUID(), sessionID: payload.sessionID, associatedAt: payload.at)
            )
        }
        record.updatedAt = payload.at
    }

    private static func advanceStage(
        record: inout TicketWorkflowRecord,
        at: Date,
        now: Date
    ) throws {
        try ensureActiveNotBlocked(record)
        guard requiredStepsSatisfied(in: record, stage: record.currentStage) else {
            throw ReduceFailure.requiredGatesUnsatisfied
        }
        guard let next = record.currentStage.next else {
            throw ReduceFailure.requiredGatesUnsatisfied
        }
        record.currentStage = next
        record.updatedAt = at
        appendTransition(
            &record,
            code: .stageAdvanced,
            at: at,
            stage: next,
            stepID: nil,
            now: now
        )
    }

    private static func returnToImplementation(
        record: inout TicketWorkflowRecord,
        at: Date,
        now: Date
    ) throws {
        guard record.lifecycle != .closed else {
            throw ReduceFailure.alreadyClosed
        }
        record.workCycle += 1
        record.currentStage = .implement
        if record.lifecycle == .blocked {
            // Stay blocked but still invalidate; caller may clear blockers separately.
        } else {
            record.lifecycle = .active
        }
        for index in record.steps.indices {
            let role = record.steps[index].role
            if Self.codeDependentRoles.contains(role) {
                record.steps[index].outcome = .pending
                record.steps[index].updatedAt = at
                record.steps[index].satisfiedInCycle = nil
            }
        }
        record.updatedAt = at
        appendTransition(
            &record,
            code: .returnedToImplementation,
            at: at,
            stage: .implement,
            stepID: nil,
            now: now
        )
    }

    private static func setBlocker(
        record: inout TicketWorkflowRecord,
        payload: SetBlocker,
        now: Date
    ) throws {
        guard record.lifecycle != .closed else {
            throw ReduceFailure.alreadyClosed
        }
        let blocker = TicketWorkflowBlocker(
            id: UUID(),
            code: payload.code,
            createdAt: payload.at,
            clearedAt: nil
        )
        record.blockers.append(blocker)
        record.lifecycle = .blocked
        record.updatedAt = payload.at
        appendTransition(
            &record,
            code: .blocked,
            at: payload.at,
            stage: record.currentStage,
            stepID: nil,
            now: now
        )
    }

    private static func clearBlocker(
        record: inout TicketWorkflowRecord,
        payload: ClearBlocker,
        now: Date
    ) throws {
        guard record.lifecycle != .closed else {
            throw ReduceFailure.alreadyClosed
        }
        guard let index = record.blockers.firstIndex(where: { $0.id == payload.blockerID && $0.isActive }) else {
            throw ReduceFailure.stepNotFound
        }
        record.blockers[index].clearedAt = payload.at
        if !record.blockers.contains(where: \.isActive) {
            record.lifecycle = .active
        }
        record.updatedAt = payload.at
        appendTransition(
            &record,
            code: .resumed,
            at: payload.at,
            stage: record.currentStage,
            stepID: nil,
            now: now
        )
    }

    private static func closeWorkflow(
        record: inout TicketWorkflowRecord,
        payload: CloseWorkflow,
        terminalJiraStatus: String,
        now: Date
    ) throws {
        guard record.lifecycle != .closed else {
            throw ReduceFailure.alreadyClosed
        }
        guard record.lifecycle != .blocked else {
            throw ReduceFailure.lifecycleBlocked
        }
        guard allRequiredInternalGatesSatisfied(record) else {
            throw ReduceFailure.requiredGatesUnsatisfied
        }

        let decision = TicketJiraClosureDecision.evaluate(
            observation: payload.observation,
            expectedAssociation: record.association,
            terminalStatus: terminalJiraStatus,
            now: now
        )
        switch decision {
        case .accepted:
            if let index = record.steps.firstIndex(where: { $0.role == .jiraClosureVerified }) {
                record.steps[index].outcome = .succeeded
                record.steps[index].updatedAt = payload.at
                record.steps[index].satisfiedInCycle = record.workCycle
            }
            record.lifecycle = .closed
            record.closedAt = payload.at
            record.updatedAt = payload.at
            appendTransition(
                &record,
                code: .closed,
                at: payload.at,
                stage: .close,
                stepID: nil,
                now: now
            )
        case .rejected(let reason):
            throw ReduceFailure.observationRejected(reason)
        }
    }

    private static func markInterrupted(
        record: inout TicketWorkflowRecord,
        payload: MarkInterrupted,
        now: Date
    ) {
        let ids = Set(payload.stepIDs)
        for index in record.steps.indices where ids.contains(record.steps[index].id) {
            if record.steps[index].outcome == .running {
                record.steps[index].outcome = .interrupted
                record.steps[index].updatedAt = payload.at
                appendTransition(
                    &record,
                    code: .stepInterrupted,
                    at: payload.at,
                    stage: record.steps[index].stage,
                    stepID: record.steps[index].id,
                    now: now
                )
            }
        }
        record.updatedAt = payload.at
    }

    private static func markRevalidationRequired(
        record: inout TicketWorkflowRecord,
        payload: MarkRevalidationRequired,
        now: Date
    ) {
        let ids = Set(payload.stepIDs)
        for index in record.steps.indices where ids.contains(record.steps[index].id) {
            let step = record.steps[index]
            let isAutomated = Self.automatedOnlyRoles.contains(step.role)
                || step.completionSource == .jobResult
                || step.completionSource == .jiraObservation
            if isAutomated && (step.outcome == .succeeded || step.outcome == .acknowledged) {
                record.steps[index].outcome = .previouslyPassedNeedsRevalidation
                record.steps[index].updatedAt = payload.at
                record.steps[index].satisfiedInCycle = nil
                appendTransition(
                    &record,
                    code: .reconciliationNeeded,
                    at: payload.at,
                    stage: step.stage,
                    stepID: step.id,
                    now: now
                )
            }
        }
        if record.lifecycle == .active {
            record.lifecycle = .needsReconciliation
        }
        record.updatedAt = payload.at
    }

    private static func associateSession(
        record: inout TicketWorkflowRecord,
        payload: AssociateSession,
        now: Date
    ) {
        if !record.associatedSessionIDs.contains(where: { $0.sessionID == payload.sessionID }) {
            record.associatedSessionIDs.append(
                TicketAssociatedSession(id: UUID(), sessionID: payload.sessionID, associatedAt: payload.at)
            )
        }
        record.updatedAt = payload.at
        _ = now
    }

    // MARK: - Plumbing

    private enum ReduceFailure: Error {
        case unknownWorkflow
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

    private static func mapError(_ failure: ReduceFailure) -> TicketWorkflowReduceError {
        switch failure {
        case .unknownWorkflow: return .unknownWorkflow
        case .wrongWorkflow: return .wrongWorkflow
        case .stepNotFound: return .stepNotFound
        case .stepNotManual: return .stepNotManual
        case .stepNotOptional: return .stepNotOptional
        case .requiredGatesUnsatisfied: return .requiredGatesUnsatisfied
        case .automatedCannotAcknowledge: return .automatedCannotAcknowledge
        case .evidenceNotApplicable: return .evidenceNotApplicable
        case .observationRejected(let reason): return .observationRejected(reason)
        case .alreadyClosed: return .alreadyClosed
        case .lifecycleBlocked: return .lifecycleBlocked
        }
    }

    private static func ensureMutableLifecycle(_ record: TicketWorkflowRecord) throws {
        if record.lifecycle == .closed {
            throw ReduceFailure.alreadyClosed
        }
    }

    private static func ensureActiveNotBlocked(_ record: TicketWorkflowRecord) throws {
        try ensureMutableLifecycle(record)
        if record.lifecycle == .blocked {
            throw ReduceFailure.lifecycleBlocked
        }
    }

    private static func mutate(
        workflows: inout [UUID: TicketWorkflowRecord],
        id: UUID,
        body: (inout TicketWorkflowRecord) throws -> Void
    ) -> TicketWorkflowReduceResult {
        guard var record = workflows[id] else {
            return result(error: .unknownWorkflow)
        }
        do {
            try body(&record)
            workflows[id] = record
            return result(record: record)
        } catch let failure as ReduceFailure {
            // Persist rejection transitions that mutated before throw (e.g. evidenceRejected).
            workflows[id] = record
            return TicketWorkflowReduceResult(
                record: record,
                removedWorkflowID: nil,
                error: mapError(failure)
            )
        } catch {
            return result(record: record, error: .unknownWorkflow)
        }
    }

    private static func result(
        record: TicketWorkflowRecord? = nil,
        removed: UUID? = nil,
        error: TicketWorkflowReduceError? = nil
    ) -> TicketWorkflowReduceResult {
        TicketWorkflowReduceResult(record: record, removedWorkflowID: removed, error: error)
    }

    private static func appendTransition(
        _ record: inout TicketWorkflowRecord,
        code: TicketWorkflowTransitionCode,
        at: Date,
        stage: TicketWorkflowStage?,
        stepID: UUID?,
        now: Date
    ) {
        _ = now
        record.transitionHistory.append(
            TicketWorkflowTransition(
                id: UUID(),
                at: at,
                code: code,
                stage: stage,
                stepID: stepID,
                workCycle: record.workCycle
            )
        )
        if record.transitionHistory.count > maxTransitionHistory {
            record.transitionHistory.removeFirst(record.transitionHistory.count - maxTransitionHistory)
        }
    }
}
