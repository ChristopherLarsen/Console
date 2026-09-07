import Foundation

/// Versioned default checklist. Template edits mint a new version; existing
/// workflows keep the version they were started with.
enum TicketWorkflowDefaultTemplate {
    static let templateID = UUID(uuidString: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")!
    static let version = 1

    static func make() -> TicketWorkflowTemplate {
        TicketWorkflowTemplate(
            id: templateID,
            version: version,
            displayName: "Default",
            steps: defaultSteps(),
            terminalJiraStatus: TicketWorkflowTemplate.defaultTerminalJiraStatus
        )
    }

    static func defaultSteps() -> [TicketChecklistStepTemplate] {
        [
            step(.understand, .scopeUnderstood, "Scope understood",
                 required: true, source: .developerAcknowledgement),
            step(.understand, .acceptanceUnderstood, "Acceptance criteria understood",
                 required: true, source: .developerAcknowledgement),

            step(.prepare, .workspaceSelected, "Workspace selected and available",
                 required: true, source: .composite),
            step(.prepare, .branchPrepared, "Branch/workspace preparation confirmed",
                 required: true, source: .developerAcknowledgement),

            step(.implement, .implementationCompleted, "Implementation completed",
                 required: true, source: .developerAcknowledgement),
            step(.implement, .sessionsVisible, "Associated sessions visible",
                 required: true, source: .sessionActivity),

            step(.verify, .buildPassed, "Build passed",
                 required: true, source: .jobResult),
            step(.verify, .testsPassed, "Selected tests passed",
                 required: true, source: .jobResult),
            step(.verify, .selfReviewCompleted, "Self-review completed",
                 required: true, source: .developerAcknowledgement),
            step(.verify, .manualDeviceCheck, "Manual device check",
                 required: true, source: .developerAcknowledgement),

            step(.review, .mrPrepared, "MR prepared",
                 required: true, source: .developerAcknowledgement),
            step(.review, .feedbackAddressed, "Feedback addressed",
                 required: true, source: .developerAcknowledgement),
            step(.review, .reviewApprovalConfirmed, "Review approval confirmed",
                 required: true, source: .developerAcknowledgement),

            step(.deliver, .mergeConfirmed, "Merge confirmed",
                 required: true, source: .developerAcknowledgement),
            step(.deliver, .qaCompleted, "QA completed",
                 required: true, source: .developerAcknowledgement),
            step(.deliver, .releaseRequirementsSatisfied, "Release requirements satisfied",
                 required: false, source: .developerAcknowledgement),

            step(.close, .documentationCleanup, "Documentation/cleanup completed",
                 required: false, source: .developerAcknowledgement),
            step(.close, .jiraClosureVerified, "Jira closure verified",
                 required: true, source: .jiraObservation, protected: true),
        ]
    }

    private static func step(
        _ stage: TicketWorkflowStage,
        _ role: TicketStepRole,
        _ title: String,
        required: Bool,
        source: TicketStepCompletionSource,
        protected: Bool = false
    ) -> TicketChecklistStepTemplate {
        TicketChecklistStepTemplate(
            id: stableStepID(stage: stage, role: role),
            stage: stage,
            role: role,
            title: title,
            isRequired: required,
            completionSource: source,
            isProtected: protected || role == .jiraClosureVerified
        )
    }

    /// Stable IDs so tests and template versioning can refer to steps.
    private static func stableStepID(stage: TicketWorkflowStage, role: TicketStepRole) -> UUID {
        let seed = "ticket.workflow.default.v1.\(stage.rawValue).\(role.rawValue)"
        return uuid5(name: seed)
    }

    /// Deterministic UUID from a name (not RFC-4122 SHA-1; fine for local IDs).
    private static func uuid5(name: String) -> UUID {
        var hash = [UInt8](repeating: 0, count: 16)
        let bytes = Array(name.utf8)
        for (index, byte) in bytes.enumerated() {
            hash[index % 16] ^= byte &+ UInt8(index & 0xFF)
        }
        hash[6] = (hash[6] & 0x0F) | 0x50
        hash[8] = (hash[8] & 0x3F) | 0x80
        return UUID(uuid: (
            hash[0], hash[1], hash[2], hash[3],
            hash[4], hash[5], hash[6], hash[7],
            hash[8], hash[9], hash[10], hash[11],
            hash[12], hash[13], hash[14], hash[15]
        ))
    }
}
