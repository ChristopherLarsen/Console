import XCTest
@testable import Console

final class TicketJiraObservationPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_060)
    private let token = TicketAssociationToken(digest: Data([0x11, 0x22, 0x33]))

    func testAcceptedWhenFreshMatchedTerminalVisibleAndAssociated() {
        let observation = makeObservation(
            status: "Closed",
            observedAt: now.addingTimeInterval(-10),
            observed: token
        )

        XCTAssertEqual(
            TicketJiraObservationPolicy.evaluate(
                observation,
                now: now,
                currentNavigationGeneration: 3,
                expectedOriginHost: "jira.example.test"
            ),
            .accepted
        )
    }

    func testRejectsStaleAgeAndStaleNavigationGeneration() {
        let staleAge = makeObservation(
            status: "Closed",
            observedAt: now.addingTimeInterval(-61),
            observed: token
        )
        XCTAssertEqual(
            TicketJiraObservationPolicy.evaluate(staleAge, now: now, currentNavigationGeneration: 3),
            .rejected(.stale)
        )

        let staleNav = makeObservation(
            status: "Closed",
            observedAt: now.addingTimeInterval(-5),
            navigationGeneration: 2,
            observed: token
        )
        XCTAssertEqual(
            TicketJiraObservationPolicy.evaluate(staleNav, now: now, currentNavigationGeneration: 9),
            .rejected(.stale)
        )
    }

    func testRejectsAuthUnsupportedFailureVisibilityAndContradiction() {
        XCTAssertEqual(
            TicketJiraObservationPolicy.evaluate(
                makeNonMatched(.authenticationRequired),
                now: now
            ),
            .rejected(.authenticationPage)
        )
        XCTAssertEqual(
            TicketJiraObservationPolicy.evaluate(
                makeNonMatched(.unsupportedPage),
                now: now
            ),
            .rejected(.unsupportedPage)
        )
        XCTAssertEqual(
            TicketJiraObservationPolicy.evaluate(
                makeNonMatched(.extractionFailed),
                now: now
            ),
            .rejected(.extractionFailure)
        )

        var hidden = makeObservation(status: "Closed", observedAt: now, observed: token)
        hidden.isFromVisibleIssuePage = false
        XCTAssertEqual(
            TicketJiraObservationPolicy.evaluate(hidden, now: now, currentNavigationGeneration: 3),
            .rejected(.notVisibleIssuePage)
        )

        XCTAssertEqual(
            TicketJiraObservationPolicy.evaluate(
                makeObservation(status: "Closed", observedAt: now, observed: token),
                now: now,
                currentNavigationGeneration: 3,
                hasInterveningContradiction: true
            ),
            .rejected(.interveningContradiction)
        )
    }

    func testRejectsWrongOriginWrongTicketMissingAssociationAndNonTerminal() {
        XCTAssertEqual(
            TicketJiraObservationPolicy.evaluate(
                makeObservation(status: "Closed", observedAt: now, observed: token),
                now: now,
                currentNavigationGeneration: 3,
                expectedOriginHost: "other.example.test"
            ),
            .rejected(.wrongOrigin)
        )

        let other = TicketAssociationToken(digest: Data([0xFF]))
        XCTAssertEqual(
            TicketJiraObservationPolicy.evaluate(
                makeObservation(status: "Closed", observedAt: now, observed: other),
                now: now,
                currentNavigationGeneration: 3
            ),
            .rejected(.wrongTicket)
        )

        XCTAssertEqual(
            TicketJiraObservationPolicy.evaluate(
                makeObservation(status: "Closed", observedAt: now, observed: nil),
                now: now,
                currentNavigationGeneration: 3
            ),
            .rejected(.missingAssociation)
        )

        XCTAssertEqual(
            TicketJiraObservationPolicy.evaluate(
                makeObservation(status: "In Progress", observedAt: now, observed: token),
                now: now,
                currentNavigationGeneration: 3
            ),
            .rejected(.statusNotTerminal)
        )
    }

    func testStatusNormalizationAcceptsWhitespaceAndCaseVariants() {
        let observation = makeObservation(
            status: "  CLOSED ",
            observedAt: now,
            observed: token
        )
        XCTAssertEqual(
            TicketJiraObservationPolicy.evaluate(
                observation,
                terminalStatus: "closed",
                now: now,
                currentNavigationGeneration: 3
            ),
            .accepted
        )
        XCTAssertTrue(
            TicketJiraObservationPolicy.statusMatchesTerminal("Done", terminal: "done")
        )
        XCTAssertFalse(
            TicketJiraObservationPolicy.statusMatchesTerminal("Done", terminal: "Closed")
        )
    }

    func testSentinelIssueKeyNeverEncodedInDurableDTO() throws {
        let observation = makeObservation(
            key: "SENSITIVE_TICKET_KEY",
            status: "Closed",
            observedAt: now,
            observed: token
        )
        XCTAssertEqual(
            TicketJiraObservationPolicy.evaluate(
                observation,
                now: now,
                currentNavigationGeneration: 3
            ),
            .accepted
        )

        // Memory observation may carry sentinel key/status strings; durable
        // DTOs must never encode them.
        if case let .matched(detail) = observation.extraction {
            XCTAssertEqual(detail.issueKey, "SENSITIVE_TICKET_KEY")
            _ = detail.statusLabel
        }

        let store = TicketWorkflowStoreDTO(
            formatVersion: TicketWorkflowStoreDTO.currentFormatVersion,
            workflows: [
                TicketWorkflowRecordDTO(
                    id: UUID(),
                    associationDigest: token.digest,
                    templateID: UUID(),
                    templateVersion: 1,
                    lifecycle: .closed,
                    currentStage: .close,
                    workCycle: 1,
                    steps: [],
                    blockers: [],
                    associatedSessionIDs: [],
                    workspaceID: nil,
                    createdAt: now,
                    updatedAt: now,
                    closedAt: now,
                    transitionHistory: []
                )
            ],
            templates: []
        )
        let data = try JSONEncoder().encode(store)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("SENSITIVE_TICKET_KEY"))
        XCTAssertFalse(json.contains("SENSITIVE_STATUS"))
        XCTAssertFalse(json.contains("SENSITIVE_TITLE"))
    }

    // MARK: - Helpers

    private func makeObservation(
        key: String = "DEMO-42",
        status: String,
        observedAt: Date,
        navigationGeneration: Int = 3,
        observed: TicketAssociationToken?
    ) -> TicketJiraObservation {
        let detail = TicketJiraMatchedDetail(
            issueKey: key,
            statusLabel: status,
            originHost: "jira.example.test",
            pageURL: URL(string: "https://jira.example.test/browse/\(key)")!,
            observedAt: observedAt,
            navigationGeneration: navigationGeneration
        )
        return TicketJiraObservationBuilder.makeObservation(
            extraction: .matched(detail),
            expectedAssociation: token,
            observedAssociation: observed,
            navigationGeneration: navigationGeneration,
            isFromVisibleIssuePage: true
        )
    }

    private func makeNonMatched(_ extraction: TicketJiraDetailExtraction) -> TicketJiraObservation {
        TicketJiraObservationBuilder.makeObservation(
            extraction: extraction,
            expectedAssociation: token,
            observedAssociation: token,
            observedAt: now,
            navigationGeneration: 3,
            isFromVisibleIssuePage: true
        )
    }
}
