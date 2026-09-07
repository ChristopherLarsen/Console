import Foundation

/// Display strings for Ticket Work UI. Kept out of durable domain types.
enum TicketWorkUILabels {
    static func lifecycle(_ value: TicketWorkflowLifecycle) -> String {
        switch value {
        case .active: return "Active"
        case .blocked: return "Blocked"
        case .closed: return "Closed"
        case .needsReconciliation: return "Needs reconciliation"
        }
    }

    static func blocker(_ code: TicketBlockerCode) -> String {
        switch code {
        case .waitingForInformation: return "Waiting for information"
        case .waitingForReviewer: return "Waiting for reviewer"
        case .waitingForQA: return "Waiting for QA"
        case .waitingForExternalAction: return "Waiting for external action"
        case .workspaceRepairNeeded: return "Workspace repair needed"
        }
    }

    static func outcome(_ value: TicketStepOutcome) -> String {
        switch value {
        case .pending: return "Pending"
        case .skipped: return "Skipped"
        case .acknowledged: return "Acknowledged"
        case .running: return "Running"
        case .succeeded: return "Succeeded"
        case .failed: return "Failed"
        case .interrupted: return "Interrupted"
        case .previouslyPassedNeedsRevalidation: return "Needs revalidation"
        case .blocked: return "Blocked"
        case .unverified: return "Unverified"
        }
    }

    static func closeBlockedReason(_ reason: TicketJiraObservationRejection?) -> String? {
        guard let reason else { return nil }
        switch reason {
        case .stale: return "Observation is stale"
        case .wrongTicket: return "Wrong ticket"
        case .wrongOrigin: return "Wrong origin"
        case .authenticationPage: return "Sign in required"
        case .unsupportedPage: return "Unsupported page"
        case .extractionFailure: return "Could not read status"
        case .notVisibleIssuePage: return "Issue page not visible"
        case .interveningContradiction: return "Contradictory observation"
        case .missingAssociation: return "Missing association"
        case .statusNotTerminal: return "Jira status is not terminal"
        }
    }
}
