import Foundation

/// Lead-owned coordinator surface. Workers must not implement app wiring here;
/// they may assume these operations exist when documenting integration points.
@MainActor
protocol TicketWorkflowCoordinating: AnyObject {
    func trackOrOpen(association: TicketAssociationToken, workspaceID: UUID?) -> UUID
    func acknowledge(workflowID: UUID, stepID: UUID)
    func skip(workflowID: UUID, stepID: UUID)
    func startStepAction(workflowID: UUID, stepID: UUID) async
    func applyJobEvidence(_ evidence: TicketJobEvidence)
    func applyJiraObservation(_ observation: TicketJiraObservation)
    func advance(workflowID: UUID)
    func returnToImplementation(workflowID: UUID)
    func block(workflowID: UUID, code: TicketBlockerCode)
    func resume(workflowID: UUID, blockerID: UUID)
    func close(workflowID: UUID, observation: TicketJiraObservation)
    func forget(workflowID: UUID)
    func associateSession(workflowID: UUID, sessionID: UUID)
}
