import Foundation
import Observation

/// App-scoped coordinator: user actions → store events → persistence.
/// Side effects (jobs, Jira extract, session launch) stay out of the reducer.
@MainActor
@Observable
final class TicketWorkflowCoordinator: TicketWorkflowCoordinating {
    private let store: TicketWorkflowStore
    private var pendingSessionWorkflowID: UUID?

    init(store: TicketWorkflowStore) {
        self.store = store
    }

    var actionHandlers: TicketWorkActionHandlers {
        TicketWorkActionHandlers(
            acknowledge: { [weak self] workflowID, stepID in
                self?.acknowledge(workflowID: workflowID, stepID: stepID)
            },
            skip: { [weak self] workflowID, stepID in
                self?.skip(workflowID: workflowID, stepID: stepID)
            },
            startStepAction: { [weak self] workflowID, stepID in
                Task { await self?.startStepAction(workflowID: workflowID, stepID: stepID) }
            },
            advance: { [weak self] workflowID in
                self?.advance(workflowID: workflowID)
            },
            returnToImplementation: { [weak self] workflowID in
                self?.returnToImplementation(workflowID: workflowID)
            },
            block: { [weak self] workflowID, code in
                self?.block(workflowID: workflowID, code: code)
            },
            resume: { [weak self] workflowID, blockerID in
                self?.resume(workflowID: workflowID, blockerID: blockerID)
            },
            forget: { [weak self] workflowID in
                self?.forget(workflowID: workflowID)
            },
            close: { [weak self] workflowID in
                // Close requires a fresh observation from the detail extractor;
                // navigate to Jira so the user can re-check status.
                self?.checkStatusAgain(workflowID: workflowID)
            },
            openInJira: { [weak self] workflowID in
                self?.openInJira(workflowID: workflowID)
            },
            checkStatus: { [weak self] workflowID in
                self?.checkStatusAgain(workflowID: workflowID)
            },
            reconnectInJira: { [weak self] workflowID in
                self?.openInJira(workflowID: workflowID)
            },
            selectSession: { sessionID in
                ConsoleNavigation.showSessions()
                // Session selection is owned by SessionStore; caller may refine.
                _ = sessionID
            },
            commitTemplate: { [weak self] template in
                self?.commitTemplate(template)
            }
        )
    }

    @discardableResult
    func trackOrOpen(association: TicketAssociationToken, workspaceID: UUID?) -> UUID {
        if let existing = store.workflows.values.first(where: { $0.association == association }) {
            ConsoleNavigation.show(.ticketWork)
            return existing.id
        }
        let template = store.templates.values
            .sorted { $0.version > $1.version }
            .first ?? TicketWorkflowDefaultTemplate.make()
        let workflowID = UUID()
        let steps = template.steps.map { TicketChecklistStepState(from: $0) }
        let now = Date()
        _ = store.dispatch(
            .trackingStarted(
                TrackingStarted(
                    eventID: UUID(),
                    workflowID: workflowID,
                    association: association,
                    templateID: template.id,
                    templateVersion: template.version,
                    steps: steps,
                    workspaceID: workspaceID,
                    at: now
                )
            ),
            now: now
        )
        Task { await store.saveProgress() }
        ConsoleNavigation.show(.ticketWork)
        return workflowID
    }

    func acknowledge(workflowID: UUID, stepID: UUID) {
        _ = store.dispatch(
            .acknowledgeStep(
                AcknowledgeStep(eventID: UUID(), workflowID: workflowID, stepID: stepID, at: Date())
            )
        )
        Task { await store.saveProgress() }
    }

    func skip(workflowID: UUID, stepID: UUID) {
        _ = store.dispatch(
            .skipStep(SkipStep(eventID: UUID(), workflowID: workflowID, stepID: stepID, at: Date()))
        )
        Task { await store.saveProgress() }
    }

    func startStepAction(workflowID: UUID, stepID: UUID) async {
        // Job/simulator enqueue is wired when Build/Test/Simulator bridges attach.
        // Mark running only when an execution context exists; otherwise no-op.
        _ = (workflowID, stepID)
    }

    func applyJobEvidence(_ evidence: TicketJobEvidence) {
        let current = evidence.context.sourceFingerprint
        let event = TicketJobEvidenceMapper.makeEvent(evidence: evidence, currentFingerprint: current)
        _ = store.dispatch(.applyJobEvidence(event))
        Task { await store.saveProgress() }
    }

    func applyJiraObservation(_ observation: TicketJiraObservation) {
        guard let workflowID = store.workflows.values.first(where: {
            $0.association == observation.expectedAssociation
        })?.id else { return }
        _ = store.dispatch(
            .applyJiraObservation(
                ApplyJiraObservation(
                    eventID: UUID(),
                    workflowID: workflowID,
                    observation: observation,
                    at: Date()
                )
            )
        )
        Task { await store.saveProgress() }
    }

    func advance(workflowID: UUID) {
        _ = store.dispatch(
            .advanceStage(AdvanceStage(eventID: UUID(), workflowID: workflowID, at: Date()))
        )
        Task { await store.saveProgress() }
    }

    func returnToImplementation(workflowID: UUID) {
        _ = store.dispatch(
            .returnToImplementation(
                ReturnToImplementation(eventID: UUID(), workflowID: workflowID, at: Date())
            )
        )
        Task { await store.saveProgress() }
    }

    func block(workflowID: UUID, code: TicketBlockerCode) {
        _ = store.dispatch(
            .setBlocker(
                SetBlocker(eventID: UUID(), workflowID: workflowID, code: code, at: Date())
            )
        )
        Task { await store.saveProgress() }
    }

    func resume(workflowID: UUID, blockerID: UUID) {
        _ = store.dispatch(
            .clearBlocker(
                ClearBlocker(
                    eventID: UUID(),
                    workflowID: workflowID,
                    blockerID: blockerID,
                    at: Date()
                )
            )
        )
        Task { await store.saveProgress() }
    }

    func close(workflowID: UUID, observation: TicketJiraObservation) {
        _ = store.dispatch(
            .closeWorkflow(
                CloseWorkflow(
                    eventID: UUID(),
                    workflowID: workflowID,
                    observation: observation,
                    at: Date()
                )
            )
        )
        Task { await store.saveProgress() }
    }

    func forget(workflowID: UUID) {
        _ = store.dispatch(
            .forgetWorkflow(ForgetWorkflow(eventID: UUID(), workflowID: workflowID, at: Date()))
        )
        Task { await store.saveProgress() }
    }

    func associateSession(workflowID: UUID, sessionID: UUID) {
        _ = store.dispatch(
            .associateSession(
                AssociateSession(
                    eventID: UUID(),
                    workflowID: workflowID,
                    sessionID: sessionID,
                    at: Date()
                )
            )
        )
        Task { await store.saveProgress() }
    }

    /// Remember which workflow should receive the next successfully created session.
    func beginPendingSessionAssociation(workflowID: UUID) {
        pendingSessionWorkflowID = workflowID
    }

    func cancelPendingSessionAssociation() {
        pendingSessionWorkflowID = nil
    }

    /// Call only after a session was successfully created.
    func completePendingSessionAssociation(sessionID: UUID) {
        guard let workflowID = pendingSessionWorkflowID else { return }
        pendingSessionWorkflowID = nil
        associateSession(workflowID: workflowID, sessionID: sessionID)
    }

    func handleSessionLifecycle(sessionID: UUID, event: SessionLifecycleEvent) {
        let kind: TicketSessionActivityKind?
        switch event {
        case .sessionStarted:
            kind = .sessionCreated
        case .turnCompleted, .completionReported:
            kind = .turnCompleted
        case .sessionEnded, .processTerminated:
            kind = .sessionEnded
        default:
            kind = nil
        }
        guard let kind else { return }
        for workflow in store.workflows.values where workflow.associatedSessionIDs.contains(where: { $0.sessionID == sessionID }) {
            _ = store.dispatch(
                .applySessionActivity(
                    ApplySessionActivity(
                        eventID: UUID(),
                        workflowID: workflow.id,
                        sessionID: sessionID,
                        kind: kind,
                        at: Date()
                    )
                )
            )
        }
        Task { await store.saveProgress() }
    }

    private func openInJira(workflowID: UUID) {
        if let url = store.runtimeContext[workflowID]?.issueURL {
            JiraDeepLink.shared.set(url: url)
        }
        ConsoleNavigation.show(.jira)
    }

    private func checkStatusAgain(workflowID: UUID) {
        _ = workflowID
        ConsoleNavigation.show(.jira)
    }

    private func commitTemplate(_ template: TicketWorkflowTemplate) {
        store.upsertTemplate(template)
        Task { await store.saveProgress() }
    }
}
