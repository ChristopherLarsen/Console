import XCTest
@testable import Console

@MainActor
final class TicketWorkflowCoordinatorTests: XCTestCase {

    func testTrackOrOpenCreatesWorkflowAndReopensExisting() {
        let store = TicketWorkflowStore()
        let coordinator = TicketWorkflowCoordinator(store: store)
        let token = TicketAssociationToken(digest: Data(repeating: 0x11, count: 32))

        let first = coordinator.trackOrOpen(association: token, workspaceID: nil)
        let second = coordinator.trackOrOpen(association: token, workspaceID: nil)

        XCTAssertEqual(first, second)
        XCTAssertEqual(store.workflows.count, 1)
        XCTAssertEqual(store.workflows[first]?.association, token)
        XCTAssertEqual(store.workflows[first]?.lifecycle, .active)
    }

    func testCloseRejectedWhenInternalGatesIncomplete() {
        let store = TicketWorkflowStore()
        let coordinator = TicketWorkflowCoordinator(store: store)
        let token = TicketAssociationToken(digest: Data(repeating: 0x22, count: 32))
        let workflowID = coordinator.trackOrOpen(association: token, workspaceID: nil)

        let now = Date()
        let observation = TicketJiraObservation(
            extraction: .matched(
                TicketJiraMatchedDetail(
                    issueKey: "SYN-1",
                    statusLabel: TicketWorkflowTemplate.defaultTerminalJiraStatus,
                    originHost: "example.invalid",
                    pageURL: URL(string: "https://example.invalid/browse/SYN-1")!,
                    observedAt: now,
                    navigationGeneration: 1
                )
            ),
            expectedAssociation: token,
            observedAssociation: token,
            observedAt: now,
            navigationGeneration: 1,
            isFromVisibleIssuePage: true
        )

        coordinator.close(workflowID: workflowID, observation: observation)

        XCTAssertEqual(store.workflows[workflowID]?.lifecycle, .active)
        XCTAssertNil(store.workflows[workflowID]?.closedAt)
    }

    func testStartStepActionNoOpsWithoutBuildDependencies() async {
        let store = TicketWorkflowStore()
        let coordinator = TicketWorkflowCoordinator(store: store)
        let token = TicketAssociationToken(digest: Data(repeating: 0x33, count: 32))
        let workflowID = coordinator.trackOrOpen(association: token, workspaceID: UUID())
        guard let stepID = store.workflows[workflowID]?.steps.first(where: { $0.role == .buildPassed })?.id else {
            return XCTFail("expected buildPassed step")
        }

        await coordinator.startStepAction(workflowID: workflowID, stepID: stepID)

        XCTAssertEqual(
            store.workflows[workflowID]?.steps.first(where: { $0.id == stepID })?.outcome,
            .pending
        )
    }

    func testSessionLifecycleFansOutToAssociatedWorkflow() {
        let store = TicketWorkflowStore()
        let coordinator = TicketWorkflowCoordinator(store: store)
        let token = TicketAssociationToken(digest: Data(repeating: 0x44, count: 32))
        let workflowID = coordinator.trackOrOpen(association: token, workspaceID: nil)
        let sessionID = UUID()
        coordinator.associateSession(workflowID: workflowID, sessionID: sessionID)

        coordinator.handleSessionLifecycle(sessionID: sessionID, event: .turnCompleted)

        let associated = store.workflows[workflowID]?.associatedSessionIDs.contains {
            $0.sessionID == sessionID
        }
        XCTAssertEqual(associated, true)
    }

    func testApplyJiraObservationMatchesAssociation() {
        let store = TicketWorkflowStore()
        let coordinator = TicketWorkflowCoordinator(store: store)
        let token = TicketAssociationToken(digest: Data(repeating: 0x55, count: 32))
        let workflowID = coordinator.trackOrOpen(association: token, workspaceID: nil)
        let now = Date()
        let observation = TicketJiraObservation(
            extraction: .matched(
                TicketJiraMatchedDetail(
                    issueKey: "SYN-2",
                    statusLabel: "In Progress",
                    originHost: "example.invalid",
                    pageURL: URL(string: "https://example.invalid/browse/SYN-2")!,
                    observedAt: now,
                    navigationGeneration: 2
                )
            ),
            expectedAssociation: token,
            observedAssociation: token,
            observedAt: now,
            navigationGeneration: 2,
            isFromVisibleIssuePage: true
        )

        coordinator.applyJiraObservation(observation)

        XCTAssertEqual(store.workflows[workflowID]?.lifecycle, .active)
    }
}
