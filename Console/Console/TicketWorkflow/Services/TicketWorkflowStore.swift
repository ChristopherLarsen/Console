import Foundation
import Observation

/// App-scoped store. Package A owns reduce + presentation; Package B owns
/// durable load/save helpers below. Views observe snapshots only.
@MainActor
@Observable
final class TicketWorkflowStore {
    private(set) var workflows: [UUID: TicketWorkflowRecord] = [:]
    private(set) var seenEventIDs: Set<UUID> = []
    private(set) var templates: [UUID: TicketWorkflowTemplate] = [:]
    /// Memory-only Jira labels/URLs keyed by workflow ID.
    private(set) var runtimeContext: [UUID: TicketWorkflowRuntimeContext] = [:]
    private(set) var persistenceState: TicketWorkflowPersistenceState = .ready

    var terminalJiraStatus: String = TicketWorkflowTemplate.defaultTerminalJiraStatus

    private let identityKeyProvider: (any TicketIdentityKeyProviding)?
    private let identityKeyManager: (any TicketIdentityKeyManaging)?
    private let persister: (any TicketWorkflowPersisting)?
    private let fileStore: TicketWorkflowFileStore?

    init(
        defaultTemplate: TicketWorkflowTemplate = TicketWorkflowDefaultTemplate.make(),
        identityKeyProvider: (any TicketIdentityKeyProviding)? = nil,
        identityKeyManager: (any TicketIdentityKeyManaging)? = nil,
        persister: (any TicketWorkflowPersisting)? = nil,
        fileStore: TicketWorkflowFileStore? = nil
    ) {
        self.identityKeyManager = identityKeyManager
        self.identityKeyProvider = identityKeyProvider ?? identityKeyManager
        self.persister = persister ?? fileStore
        self.fileStore = fileStore
        templates[defaultTemplate.id] = defaultTemplate
    }

    @discardableResult
    func dispatch(_ event: TicketWorkflowEvent, now: Date = Date()) -> TicketWorkflowReduceResult {
        let result = TicketWorkflowReducer.reduce(
            workflows: &workflows,
            seenEventIDs: &seenEventIDs,
            event: event,
            terminalJiraStatus: terminalJiraStatus,
            now: now
        )
        if case .attachRuntimeContext(let payload) = event, result.error == nil {
            TicketWorkflowPresentation.applyRuntimeAttachment(payload, into: &runtimeContext)
        }
        if let removed = result.removedWorkflowID {
            TicketWorkflowPresentation.removeRuntime(workflowID: removed, from: &runtimeContext)
        }
        return result
    }

    func listSnapshots(filter: TicketWorkflowFilter) -> [TicketWorkflowListItemSnapshot] {
        TicketWorkflowPresentationBuilder.listItems(
            workflows: Array(workflows.values),
            runtime: runtimeContext,
            filter: filter,
            terminalJiraStatus: terminalJiraStatus
        )
    }

    func detailSnapshot(id: UUID) -> TicketWorkflowDetailSnapshot? {
        guard let record = workflows[id] else { return nil }
        return TicketWorkflowPresentationBuilder.detail(
            record: record,
            runtime: runtimeContext[id],
            terminalJiraStatus: terminalJiraStatus
        )
    }

    func upsertTemplate(_ template: TicketWorkflowTemplate) {
        templates[template.id] = template
        if template.id == TicketWorkflowDefaultTemplate.templateID
            || templates.count == 1 {
            terminalJiraStatus = template.terminalJiraStatus
        }
    }

    // MARK: - Package B: durable progress

    /// Loads durable progress. Restores stage/checklist state only — does not
    /// auto-rerun jobs. Coordinator should call restart hooks afterward.
    func loadProgress() async {
        guard let persister else {
            persistenceState = .ready
            return
        }

        let dto: TicketWorkflowStoreDTO
        do {
            dto = try await persister.load()
        } catch let error as TicketWorkflowPersistenceError {
            applyLoadFailure(error)
            return
        } catch {
            applyLoadFailure(.corruptStorage)
            return
        }

        let hasWorkflows = !dto.workflows.isEmpty

        if let identityKeyManager {
            do {
                let existing = try await identityKeyManager.existingInstallationSecret()
                if hasWorkflows, existing == nil {
                    persistenceState = .missingKeyNeedsRecovery
                    // Preserve on-disk bytes; do not load into memory or wipe.
                    return
                }
                if existing == nil {
                    _ = try await identityKeyManager.installationSecret()
                }
            } catch TicketWorkflowPersistenceError.keychainUnavailable {
                persistenceState = .lockedRetryable
                return
            } catch TicketWorkflowPersistenceError.missingIdentityKey {
                persistenceState = .missingKeyNeedsRecovery
                return
            } catch {
                persistenceState = .lockedRetryable
                return
            }
        } else if let identityKeyProvider {
            do {
                _ = try await identityKeyProvider.installationSecret()
            } catch TicketWorkflowPersistenceError.keychainUnavailable {
                persistenceState = .lockedRetryable
                return
            } catch TicketWorkflowPersistenceError.missingIdentityKey {
                if hasWorkflows {
                    persistenceState = .missingKeyNeedsRecovery
                    return
                }
                persistenceState = .lockedRetryable
                return
            } catch {
                persistenceState = .lockedRetryable
                return
            }
        }

        TicketWorkflowDTOMapping.apply(dto, into: &workflows, templates: &templates)
        if let first = templates.values.first {
            terminalJiraStatus = first.terminalJiraStatus
        }
        // Runtime context and seenEventIDs stay empty — memory-only / restart-fresh.
        runtimeContext = [:]
        seenEventIDs = []
        persistenceState = .ready
    }

    /// Persists allowlisted DTO fields only. On failure, keeps in-memory state
    /// and surfaces `.saveFailed` without wiping preserved recovery bytes.
    func saveProgress() async {
        guard let persister else { return }
        switch persistenceState {
        case .ready, .saveFailed:
            break
        case .lockedRetryable, .missingKeyNeedsRecovery, .corruptPreserved, .newerFormatPreserved:
            // Do not overwrite preserved corrupt / newer / recovery bytes.
            return
        }

        let dto = TicketWorkflowDTOMapping.storeDTO(workflows: workflows, templates: templates)
        do {
            try await persister.save(dto)
            persistenceState = .ready
        } catch {
            persistenceState = .saveFailed
        }
    }

    /// Opaque association token for a visible Jira issue. Never stores inputs.
    func makeAssociationToken(originHost: String, issueKey: String) async throws -> TicketAssociationToken {
        guard let identityKeyProvider else {
            throw TicketWorkflowPersistenceError.missingIdentityKey
        }
        let secret: Data
        do {
            secret = try await identityKeyProvider.installationSecret()
        } catch let error as TicketWorkflowPersistenceError {
            if error == .keychainUnavailable {
                persistenceState = .lockedRetryable
            } else if error == .missingIdentityKey {
                persistenceState = .missingKeyNeedsRecovery
            }
            throw error
        } catch {
            persistenceState = .lockedRetryable
            throw TicketWorkflowPersistenceError.keychainUnavailable
        }
        return TicketAssociationHasher.token(
            originHost: originHost,
            issueKey: issueKey,
            secret: secret
        )
    }

    /// Steps left `.running` across restarts — coordinator should mark interrupted
    /// (do not auto-rerun jobs).
    func stepsNeedingInterruptAfterRestart() -> [(workflowID: UUID, stepIDs: [UUID])] {
        workflows.values.compactMap { record in
            let ids = record.steps.filter { $0.outcome == .running }.map(\.id)
            guard !ids.isEmpty else { return nil }
            return (record.id, ids)
        }
    }

    /// Automated successes that require revalidation after restart — coordinator
    /// should mark revalidation required (do not auto-rerun jobs).
    func stepsNeedingRevalidationAfterRestart() -> [(workflowID: UUID, stepIDs: [UUID])] {
        workflows.values.compactMap { record in
            let ids = record.steps.compactMap { step -> UUID? in
                let isAutomated = TicketWorkflowReducer.automatedOnlyRoles.contains(step.role)
                    || step.completionSource == .jobResult
                    || step.completionSource == .jiraObservation
                guard isAutomated, step.outcome == .succeeded || step.outcome == .acknowledged else {
                    return nil
                }
                return step.id
            }
            guard !ids.isEmpty else { return nil }
            return (record.id, ids)
        }
    }

    /// Coordinator hook: mark running steps interrupted after restart.
    @discardableResult
    func markInterruptedAfterRestart(
        workflowID: UUID,
        stepIDs: [UUID],
        now: Date = Date()
    ) -> TicketWorkflowReduceResult {
        dispatch(
            .markInterrupted(MarkInterrupted(
                eventID: UUID(),
                workflowID: workflowID,
                stepIDs: stepIDs,
                at: now
            )),
            now: now
        )
    }

    /// Coordinator hook: mark automated successes as needing revalidation.
    @discardableResult
    func markRevalidationRequiredAfterRestart(
        workflowID: UUID,
        stepIDs: [UUID],
        now: Date = Date()
    ) -> TicketWorkflowReduceResult {
        dispatch(
            .markRevalidationRequired(MarkRevalidationRequired(
                eventID: UUID(),
                workflowID: workflowID,
                stepIDs: stepIDs,
                at: now
            )),
            now: now
        )
    }

    /// Applies interrupt + revalidation hooks for all restored workflows.
    /// Does not start jobs. Coordinator may call this after `loadProgress()`.
    func applyCoordinatorRestartHooks(now: Date = Date()) {
        for item in stepsNeedingInterruptAfterRestart() {
            _ = markInterruptedAfterRestart(
                workflowID: item.workflowID,
                stepIDs: item.stepIDs,
                now: now
            )
        }
        for item in stepsNeedingRevalidationAfterRestart() {
            _ = markRevalidationRequiredAfterRestart(
                workflowID: item.workflowID,
                stepIDs: item.stepIDs,
                now: now
            )
        }
    }

    /// Explicit recovery UX: wipe durable file + mint a new identity key.
    /// Call only after the user confirms reset (associations become unlinkable).
    func resetDurableProgressForRecovery() async throws {
        if let fileStore {
            try await fileStore.deleteStoreFile()
        } else if let persister {
            let empty = TicketWorkflowStoreDTO(
                formatVersion: TicketWorkflowStoreDTO.currentFormatVersion,
                workflows: [],
                templates: []
            )
            try await persister.save(empty)
        }
        if let identityKeyManager {
            _ = try await identityKeyManager.replaceInstallationSecret()
        }
        workflows = [:]
        seenEventIDs = []
        runtimeContext = [:]
        persistenceState = .ready
        if let defaultTemplate = templates.values.first(where: {
            $0.id == TicketWorkflowDefaultTemplate.templateID
        }) ?? templates.values.first {
            templates = [defaultTemplate.id: defaultTemplate]
            terminalJiraStatus = defaultTemplate.terminalJiraStatus
        }
        await saveProgress()
    }

    /// Retry after `.lockedRetryable` when Keychain becomes available again.
    func retryLoadAfterKeychainAvailable() async {
        await loadProgress()
    }

    // MARK: - Private

    private func applyLoadFailure(_ error: TicketWorkflowPersistenceError) {
        switch error {
        case .keychainUnavailable:
            persistenceState = .lockedRetryable
        case .missingIdentityKey:
            persistenceState = .missingKeyNeedsRecovery
        case .corruptStorage:
            persistenceState = .corruptPreserved
        case .newerFormat(let version):
            persistenceState = .newerFormatPreserved(version: version)
        case .saveFailed:
            persistenceState = .saveFailed
        }
    }
}
