import Foundation

// MARK: - Job evidence bridge (package C)

/// Maps Console-owned iOS jobs into workflow evidence without embedding
/// ticket/MR fields in argv, env, or artifact names.
nonisolated struct TicketJobEvidence: Equatable, Sendable {
    var context: TicketActionExecutionContext
    var jobState: IOSBuildJobState
    var kind: IOSBuildJobKind
    var resultBundleURL: URL?
    var finishedAt: Date?
}

nonisolated enum TicketJobEvidenceMapper {
    /// Translate a finished job + current fingerprint check into an event.
    static func makeEvent(
        evidence: TicketJobEvidence,
        currentFingerprint: TicketSourceFingerprint,
        eventID: UUID = UUID(),
        at: Date = Date()
    ) -> ApplyJobEvidence {
        let applicability = Self.applicability(
            context: evidence.context,
            current: currentFingerprint
        )
        let outcome: TicketStepOutcome
        switch (evidence.jobState, applicability) {
        case (.succeeded, .current):
            outcome = .succeeded
        case (.succeeded, .incompleteFingerprint), (.succeeded, .unverified):
            outcome = .unverified
        case (.succeeded, _):
            outcome = .unverified
        case (.failed, _):
            outcome = .failed
        case (.cancelled, _):
            outcome = .failed
        case (.timedOut, _):
            outcome = .failed
        case (.queued, _), (.running, _):
            outcome = .running
        }

        return ApplyJobEvidence(
            eventID: eventID,
            workflowID: evidence.context.workflowID,
            stepID: evidence.context.stepID,
            workCycle: evidence.context.workCycle,
            jobID: evidence.context.jobID,
            outcome: outcome,
            sourceFingerprint: currentFingerprint,
            profileFingerprint: evidence.context.profileFingerprint,
            applicability: applicability,
            at: at
        )
    }

    static func applicability(
        context: TicketActionExecutionContext,
        current: TicketSourceFingerprint
    ) -> TicketEvidenceApplicability {
        guard current.isComplete, context.sourceFingerprint.isComplete else {
            return .incompleteFingerprint
        }
        if current != context.sourceFingerprint {
            return .staleSource
        }
        return .current
    }
}

/// Profile snapshot digest for execution context (no source paths that embed
/// ticket keys — workspace-relative project path only).
nonisolated enum TicketProfileFingerprint {
    static func digest(profile: IOSProjectProfile, testSelection: IOSTestSelection?) -> String {
        var parts: [String] = [
            profile.workspaceID.uuidString,
            profile.projectPath ?? "",
            profile.scheme ?? "",
            profile.configuration ?? "",
            profile.testPlan ?? "",
            profile.simulatorUDID ?? "",
        ]
        if let testSelection {
            parts.append(contentsOf: testSelection.identifiers)
            parts.append(testSelection.testPlan ?? "")
        }
        return parts.joined(separator: "|")
    }
}
