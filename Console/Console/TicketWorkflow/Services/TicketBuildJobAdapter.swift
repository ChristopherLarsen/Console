import Foundation

/// Bridges Console-owned ``IOSBuildJob`` results into Ticket Work evidence
/// without embedding ticket/MR fields in argv, env, or artifact names.
///
/// Uses completed ``IOSProjectProfile`` / ``IOSTestSelection`` APIs and the
/// shared ``TicketJobEvidenceMapper``. Does not own a profile store or process
/// runner.
nonisolated enum TicketBuildJobAdapter {

    // MARK: - Context

    /// Build an immutable execution context for one automated job.
    static func makeExecutionContext(
        workflowID: UUID,
        stepID: UUID,
        workCycle: Int,
        workspaceID: UUID,
        checkoutPath: String,
        profile: IOSProjectProfile,
        testSelection: IOSTestSelection? = nil,
        jobID: UUID,
        sourceFingerprint: TicketSourceFingerprint,
        contextID: UUID = UUID(),
        createdAt: Date = Date()
    ) -> TicketActionExecutionContext {
        TicketActionExecutionContext(
            id: contextID,
            workflowID: workflowID,
            stepID: stepID,
            workCycle: workCycle,
            workspaceID: workspaceID,
            checkoutPath: checkoutPath,
            profileFingerprint: TicketProfileFingerprint.digest(
                profile: profile.normalized(),
                testSelection: testSelection
            ),
            sourceFingerprint: sourceFingerprint,
            jobID: jobID,
            createdAt: createdAt
        )
    }

    // MARK: - Evidence

    /// Snapshot job terminal state into workflow evidence bound to `context`.
    static func makeEvidence(
        job: IOSBuildJob,
        context: TicketActionExecutionContext
    ) -> TicketJobEvidence {
        TicketJobEvidence(
            context: context,
            jobState: job.state,
            kind: job.kind,
            resultBundleURL: job.resultBundleURL,
            finishedAt: job.finishedAt
        )
    }

    /// Map finished evidence + a fresh fingerprint into an apply event.
    static func makeApplyEvent(
        evidence: TicketJobEvidence,
        currentFingerprint: TicketSourceFingerprint,
        eventID: UUID = UUID(),
        at: Date = Date()
    ) -> ApplyJobEvidence {
        TicketJobEvidenceMapper.makeEvent(
            evidence: evidence,
            currentFingerprint: currentFingerprint,
            eventID: eventID,
            at: at
        )
    }

    // MARK: - Applicability gates

    /// Before enqueue: the captured fingerprint must be complete.
    static func applicabilityBeforeEnqueue(
        sourceFingerprint: TicketSourceFingerprint
    ) -> TicketEvidenceApplicability {
        sourceFingerprint.isComplete ? .current : .incompleteFingerprint
    }

    /// After the job finishes: compare the bound context fingerprint to a
    /// freshly captured checkout fingerprint.
    static func applicabilityAfterFinish(
        context: TicketActionExecutionContext,
        currentFingerprint: TicketSourceFingerprint
    ) -> TicketEvidenceApplicability {
        TicketJobEvidenceMapper.applicability(
            context: context,
            current: currentFingerprint
        )
    }

    /// Before accepting evidence for stage advancement: same freshness check.
    static func applicabilityBeforeAdvancement(
        context: TicketActionExecutionContext,
        currentFingerprint: TicketSourceFingerprint
    ) -> TicketEvidenceApplicability {
        TicketJobEvidenceMapper.applicability(
            context: context,
            current: currentFingerprint
        )
    }

    /// Convenience: evidence is only advancement-ready when applicability is
    /// ``TicketEvidenceApplicability/current`` and the job succeeded.
    static func isAcceptableForAdvancement(
        evidence: TicketJobEvidence,
        currentFingerprint: TicketSourceFingerprint
    ) -> Bool {
        guard evidence.jobState == .succeeded else { return false }
        let applicability = applicabilityBeforeAdvancement(
            context: evidence.context,
            currentFingerprint: currentFingerprint
        )
        return applicability == .current
    }
}

/// Associates a Ticket Work execution context with an iOS job enqueue request.
/// Kept in TicketWorkflow — does not extend ``IOSBuildJob``.
nonisolated struct TicketWorkflowJobRequest: Equatable, Sendable {
    var context: TicketActionExecutionContext
    var kind: IOSBuildJobKind
    var profile: IOSProjectProfile
    var testSelection: IOSTestSelection?

    init(
        context: TicketActionExecutionContext,
        kind: IOSBuildJobKind,
        profile: IOSProjectProfile,
        testSelection: IOSTestSelection? = nil
    ) {
        self.context = context
        self.kind = kind
        self.profile = profile.normalized()
        self.testSelection = testSelection
    }
}
