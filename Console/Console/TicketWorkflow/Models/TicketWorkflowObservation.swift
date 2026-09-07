import Foundation

// MARK: - Jira detail observation (package F)

/// Result of inspecting the currently displayed Jira issue page only.
/// List extraction is insufficient for closure.
nonisolated enum TicketJiraDetailExtraction: Equatable, Sendable {
    case matched(TicketJiraMatchedDetail)
    case authenticationRequired
    case unsupportedPage
    case extractionFailed
}

nonisolated struct TicketJiraMatchedDetail: Equatable, Sendable {
    /// Issue key as shown on the page (memory-only; not persisted).
    var issueKey: String
    /// Raw status label as shown (memory-only; not persisted).
    var statusLabel: String
    /// Normalized origin host used for association checks.
    var originHost: String
    var pageURL: URL
    var observedAt: Date
    var navigationGeneration: Int
}

nonisolated struct TicketJiraObservation: Equatable, Sendable {
    var extraction: TicketJiraDetailExtraction
    var expectedAssociation: TicketAssociationToken
    var observedAssociation: TicketAssociationToken?
    var observedAt: Date
    var navigationGeneration: Int
    var isFromVisibleIssuePage: Bool
}

nonisolated enum TicketJiraObservationRejection: String, Equatable, Sendable {
    case stale
    case wrongTicket
    case wrongOrigin
    case authenticationPage
    case unsupportedPage
    case extractionFailure
    case notVisibleIssuePage
    case interveningContradiction
    case missingAssociation
    case statusNotTerminal
}

nonisolated enum TicketJiraClosureDecision: Equatable, Sendable {
    case accepted
    case rejected(TicketJiraObservationRejection)

    /// Compatibility entry point used by the Package A reducer. Forwards to
    /// `TicketJiraObservationPolicy.evaluate` with the observation's own
    /// expected association and optional navigation freshness checks.
    static func evaluate(
        observation: TicketJiraObservation,
        expectedAssociation: TicketAssociationToken,
        terminalStatus: String,
        now: Date = Date(),
        currentNavigationGeneration: Int? = nil,
        expectedOriginHost: String? = nil,
        hasInterveningContradiction: Bool = false
    ) -> TicketJiraClosureDecision {
        var observation = observation
        // Prefer the caller's expected association when it differs from the
        // stamped value (tests / reducer close path).
        if observation.expectedAssociation != expectedAssociation {
            observation = TicketJiraObservation(
                extraction: observation.extraction,
                expectedAssociation: expectedAssociation,
                observedAssociation: observation.observedAssociation,
                observedAt: observation.observedAt,
                navigationGeneration: observation.navigationGeneration,
                isFromVisibleIssuePage: observation.isFromVisibleIssuePage
            )
        }
        return TicketJiraObservationPolicy.evaluate(
            observation,
            terminalStatus: terminalStatus,
            now: now,
            currentNavigationGeneration: currentNavigationGeneration,
            expectedOriginHost: expectedOriginHost,
            hasInterveningContradiction: hasInterveningContradiction
        )
    }
}

/// Freshness window for closure confirmation (seconds).
nonisolated enum TicketJiraObservationPolicy {
    static let maxAgeSeconds: TimeInterval = 60
    static let defaultTerminalStatus = TicketWorkflowTemplate.defaultTerminalJiraStatus

    static func isFresh(_ observation: TicketJiraObservation, now: Date = Date()) -> Bool {
        now.timeIntervalSince(observation.observedAt) <= maxAgeSeconds
    }

    static func statusMatchesTerminal(_ raw: String, terminal: String) -> Bool {
        TicketWorkflowTemplate.normalizeStatus(raw)
            == TicketWorkflowTemplate.normalizeStatus(terminal)
    }

    /// Evaluate whether an observation may satisfy Jira closure verification.
    /// Order prefers structural failures (auth/unsupported/visibility) before
    /// association and status checks so callers get actionable rejection codes.
    static func evaluate(
        _ observation: TicketJiraObservation,
        terminalStatus: String = defaultTerminalStatus,
        now: Date = Date(),
        currentNavigationGeneration: Int? = nil,
        expectedOriginHost: String? = nil,
        hasInterveningContradiction: Bool = false
    ) -> TicketJiraClosureDecision {
        switch observation.extraction {
        case .authenticationRequired:
            return .rejected(.authenticationPage)
        case .unsupportedPage:
            return .rejected(.unsupportedPage)
        case .extractionFailed:
            return .rejected(.extractionFailure)
        case .matched(let detail):
            return evaluateMatched(
                detail: detail,
                observation: observation,
                terminalStatus: terminalStatus,
                now: now,
                currentNavigationGeneration: currentNavigationGeneration,
                expectedOriginHost: expectedOriginHost,
                hasInterveningContradiction: hasInterveningContradiction
            )
        }
    }

    private static func evaluateMatched(
        detail: TicketJiraMatchedDetail,
        observation: TicketJiraObservation,
        terminalStatus: String,
        now: Date,
        currentNavigationGeneration: Int?,
        expectedOriginHost: String?,
        hasInterveningContradiction: Bool
    ) -> TicketJiraClosureDecision {
        if !observation.isFromVisibleIssuePage {
            return .rejected(.notVisibleIssuePage)
        }
        if let current = currentNavigationGeneration,
           current != observation.navigationGeneration {
            return .rejected(.stale)
        }
        if !isFresh(observation, now: now) {
            return .rejected(.stale)
        }
        if hasInterveningContradiction {
            return .rejected(.interveningContradiction)
        }
        if let expectedHost = expectedOriginHost {
            let normalizedExpected = Self.normalizeOriginHost(expectedHost)
            if detail.originHost != normalizedExpected {
                return .rejected(.wrongOrigin)
            }
        }
        guard let observed = observation.observedAssociation else {
            return .rejected(.missingAssociation)
        }
        if observed != observation.expectedAssociation {
            return .rejected(.wrongTicket)
        }
        if !statusMatchesTerminal(detail.statusLabel, terminal: terminalStatus) {
            return .rejected(.statusNotTerminal)
        }
        return .accepted
    }

    /// Lowercase host for association / origin checks. Strips a leading `www.`.
    static func normalizeOriginHost(_ host: String) -> String {
        var value = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if value.hasPrefix("www.") {
            value = String(value.dropFirst(4))
        }
        return value
    }
}

// MARK: - Presentation snapshots (immutable; views do not reimplement rules)

nonisolated struct TicketWorkflowListItemSnapshot: Equatable, Sendable, Identifiable {
    var id: UUID
    var lifecycle: TicketWorkflowLifecycle
    var stage: TicketWorkflowStage
    /// Memory-only; generic placeholder when disconnected.
    var title: String
    var jiraStatusLabel: String?
    var nextActionTitle: String?
    var isConnectedToJira: Bool
}

nonisolated struct TicketWorkflowDetailSnapshot: Equatable, Sendable, Identifiable {
    var id: UUID
    var lifecycle: TicketWorkflowLifecycle
    var stage: TicketWorkflowStage
    var workCycle: Int
    var title: String
    var jiraStatusLabel: String?
    var isConnectedToJira: Bool
    var stages: [TicketStageProgressSnapshot]
    var steps: [TicketStepSnapshot]
    var blockers: [TicketBlockerSnapshot]
    var associatedSessions: [TicketSessionSnapshot]
    var nextAction: TicketNextActionSnapshot?
    var canAdvance: Bool
    var canReturnToImplementation: Bool
    var canClose: Bool
    var closeBlockedReason: TicketJiraObservationRejection?
}

nonisolated struct TicketStageProgressSnapshot: Equatable, Sendable, Identifiable {
    var id: TicketWorkflowStage { stage }
    var stage: TicketWorkflowStage
    var isCurrent: Bool
    var isCompleted: Bool
}

nonisolated struct TicketStepSnapshot: Equatable, Sendable, Identifiable {
    var id: UUID
    var stage: TicketWorkflowStage
    var title: String
    var role: TicketStepRole
    var isRequired: Bool
    var outcome: TicketStepOutcome
    var completionSource: TicketStepCompletionSource
    var canAcknowledge: Bool
    var canSkip: Bool
    var canStartAction: Bool
}

nonisolated struct TicketBlockerSnapshot: Equatable, Sendable, Identifiable {
    var id: UUID
    var code: TicketBlockerCode
    var createdAt: Date
}

nonisolated struct TicketSessionSnapshot: Equatable, Sendable, Identifiable {
    var id: UUID
    var sessionID: UUID
    var displayName: String
}

nonisolated struct TicketNextActionSnapshot: Equatable, Sendable {
    var title: String
    var kind: TicketNextActionKind
    var workflowID: UUID
    var stepID: UUID?
}

nonisolated enum TicketNextActionKind: String, Equatable, Sendable {
    case acknowledgeStep
    case startBuild
    case startTests
    case openSimulator
    case openInJira
    case checkStatusAgain
    case advanceStage
    case confirmImplementation
    case closeWorkflow
    case resumeBlocker
    case reconnectInJira
}

// MARK: - Next card integration targets (lead adds NextTaskKind case)

/// Navigation target for a tracked workflow step. Lead wiring adds
/// `NextTaskKind.ticketWorkflowStep` and `NextOpenTarget.ticketWorkflow(...)`.
nonisolated struct TicketWorkflowNextTarget: Equatable, Sendable {
    var workflowID: UUID
    var stepID: UUID
}
