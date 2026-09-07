import Foundation

/// Shared helpers for Track Work from a currently rendered Jira ticket.
/// Issue key/title stay memory-only via AttachRuntimeContext.
enum TicketWorkTracking {
    @MainActor
    static func track(
        coordinator: TicketWorkflowCoordinator,
        store: TicketWorkflowStore,
        key: String,
        title: String?,
        status: String?,
        issueURL: URL,
        workspaceID: UUID?,
        navigationGeneration: Int = 0
    ) async {
        guard let host = issueURL.host, !key.isEmpty else { return }
        do {
            let token = try await store.makeAssociationToken(originHost: host, issueKey: key)
            let workflowID = coordinator.trackOrOpen(association: token, workspaceID: workspaceID)
            _ = store.dispatch(
                .attachRuntimeContext(
                    AttachRuntimeContext(
                        eventID: UUID(),
                        workflowID: workflowID,
                        displayKey: key,
                        displayTitle: title,
                        observedStatus: status,
                        issueURL: issueURL,
                        navigationGeneration: navigationGeneration,
                        at: Date()
                    )
                )
            )
        } catch {
            // Keychain locked — surface via store.persistenceState on next load.
        }
    }

    @MainActor
    static func isTracked(
        store: TicketWorkflowStore,
        key: String,
        issueURL: URL
    ) async -> Bool {
        guard let host = issueURL.host else { return false }
        do {
            let token = try await store.makeAssociationToken(originHost: host, issueKey: key)
            return store.workflows.values.contains { $0.association == token }
        } catch {
            return false
        }
    }
}
