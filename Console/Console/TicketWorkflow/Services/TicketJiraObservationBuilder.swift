import Foundation

/// Builds memory-only Jira observations for Ticket Work closure checks.
/// HMAC association is produced by an injected provider (Package B) or a
/// precomputed observed token — this type never persists issue keys.
nonisolated enum TicketJiraObservationBuilder {
    /// Callback signature for Package B HMAC: `(originHost, issueKey) → token`.
    typealias AssociationTokenProvider = (String, String) -> TicketAssociationToken

    /// Assemble an observation from a detail extraction plus association inputs.
    static func makeObservation(
        extraction: TicketJiraDetailExtraction,
        expectedAssociation: TicketAssociationToken,
        observedAssociation: TicketAssociationToken? = nil,
        associationTokenProvider: AssociationTokenProvider? = nil,
        observedAt: Date = Date(),
        navigationGeneration: Int,
        isFromVisibleIssuePage: Bool
    ) -> TicketJiraObservation {
        let resolvedObserved: TicketAssociationToken?
        if let observedAssociation {
            resolvedObserved = observedAssociation
        } else if case let .matched(detail) = extraction, let provider = associationTokenProvider {
            resolvedObserved = provider(detail.originHost, detail.issueKey)
        } else {
            resolvedObserved = nil
        }

        let stampedAt: Date
        let stampedGeneration: Int
        if case let .matched(detail) = extraction {
            stampedAt = detail.observedAt
            stampedGeneration = detail.navigationGeneration
        } else {
            stampedAt = observedAt
            stampedGeneration = navigationGeneration
        }

        return TicketJiraObservation(
            extraction: extraction,
            expectedAssociation: expectedAssociation,
            observedAssociation: resolvedObserved,
            observedAt: stampedAt,
            navigationGeneration: stampedGeneration,
            isFromVisibleIssuePage: isFromVisibleIssuePage
        )
    }
}
