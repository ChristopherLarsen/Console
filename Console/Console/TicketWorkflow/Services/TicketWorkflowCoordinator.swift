import Foundation
import Observation

/// App-scoped coordinator: user actions → store events → persistence.
/// Side effects (jobs, Jira extract, session launch) stay out of the reducer.
@MainActor
@Observable
final class TicketWorkflowCoordinator: TicketWorkflowCoordinating {
    private let store: TicketWorkflowStore
    private var pendingSessionWorkflowID: UUID?

    /// Optional dependencies for Build/Test/Simulator — nil in pure unit tests.
    var buildCoordinator: IOSBuildCoordinator?
    var profileStore: IOSProjectProfileStore?
    var workspaceStore: SessionWorkspaceStore?
    var fingerprintService = TicketSourceFingerprintService()
    var simulatorBridge = TicketWorkflowSimulatorBridge(processRunner: SystemProcessRunner())
    /// Last successful build product / job per workflow for Simulator handoff.
    private var lastBuiltProductByWorkflow: [UUID: IOSBuiltProduct] = [:]
    private var lastSucceededJobByWorkflow: [UUID: IOSBuildJob] = [:]
    private let productResolver: SimulatorService

    init(
        store: TicketWorkflowStore,
        processRunner: any ProcessRunning = SystemProcessRunner()
    ) {
        self.store = store
        self.simulatorBridge = TicketWorkflowSimulatorBridge(processRunner: processRunner)
        self.productResolver = SimulatorService(processRunner: processRunner)
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
                Task { await self?.observeAndClose(workflowID: workflowID) }
            },
            openInJira: { [weak self] workflowID in
                self?.openInJira(workflowID: workflowID)
            },
            checkStatus: { [weak self] workflowID in
                Task { await self?.checkStatusAgain(workflowID: workflowID) }
            },
            reconnectInJira: { [weak self] workflowID in
                self?.openInJira(workflowID: workflowID)
            },
            selectSession: { sessionID in
                ConsoleNavigation.showSessions()
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
        guard let record = store.workflows[workflowID],
              let step = record.steps.first(where: { $0.id == stepID }) else { return }

        switch step.role {
        case .buildPassed:
            await runBuildOrTest(workflowID: workflowID, stepID: stepID, kind: .build)
        case .testsPassed:
            await runBuildOrTest(workflowID: workflowID, stepID: stepID, kind: .runSelectedTests)
        case .manualDeviceCheck:
            await runSimulator(workflowID: workflowID, stepID: stepID)
        default:
            break
        }
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
        lastBuiltProductByWorkflow.removeValue(forKey: workflowID)
        lastSucceededJobByWorkflow.removeValue(forKey: workflowID)
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
        lastBuiltProductByWorkflow.removeValue(forKey: workflowID)
        lastSucceededJobByWorkflow.removeValue(forKey: workflowID)
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

    func beginPendingSessionAssociation(workflowID: UUID) {
        pendingSessionWorkflowID = workflowID
    }

    func cancelPendingSessionAssociation() {
        pendingSessionWorkflowID = nil
    }

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

    // MARK: - Jira observation / close

    /// Fresh DOM observation on the visible Jira issue page, then close when accepted.
    func observeAndClose(workflowID: UUID) async {
        guard let observation = await makeCurrentJiraObservation(for: workflowID) else {
            openInJira(workflowID: workflowID)
            return
        }
        applyJiraObservation(observation)
        let decision = TicketJiraClosureDecision.evaluate(
            observation: observation,
            expectedAssociation: observation.expectedAssociation,
            terminalStatus: store.terminalJiraStatus
        )
        switch decision {
        case .accepted:
            close(workflowID: workflowID, observation: observation)
        case .rejected:
            openInJira(workflowID: workflowID)
        }
    }

    func checkStatusAgain(workflowID: UUID) async {
        if let observation = await makeCurrentJiraObservation(for: workflowID) {
            applyJiraObservation(observation)
            if let status = memoryStatusLabel(from: observation) {
                attachObservedStatus(workflowID: workflowID, status: status, observation: observation)
            }
        } else {
            openInJira(workflowID: workflowID)
        }
    }

    // MARK: - Private execution

    private func runBuildOrTest(
        workflowID: UUID,
        stepID: UUID,
        kind: IOSBuildJobKind
    ) async {
        guard let buildCoordinator,
              let profileStore,
              let workspaceStore,
              let record = store.workflows[workflowID],
              let workspaceID = record.workspaceID,
              let workspace = workspaceStore.workspace(withID: workspaceID)
        else { return }

        let profile = profileStore.profileOrEmpty(for: workspaceID).normalized()
        let checkout = workspace.directoryPath
        let fingerprint = await fingerprintService.fingerprint(checkoutPath: checkout)
        guard TicketBuildJobAdapter.applicabilityBeforeEnqueue(sourceFingerprint: fingerprint) == .current else {
            return
        }

        let testSelection: IOSTestSelection?
        switch kind {
        case .build:
            testSelection = nil
        case .runSelectedTests:
            let selection = IOSTestSelection(identifiers: [], testPlan: profile.testPlan)
                .resolving(profile: profile)
            guard selection.isExplicit else { return }
            testSelection = selection
        }

        let jobID: UUID
        do {
            switch kind {
            case .build:
                jobID = try buildCoordinator.submitBuild(profile: profile)
            case .runSelectedTests:
                jobID = try buildCoordinator.submitSelectedTests(
                    profile: profile,
                    identifiers: testSelection?.identifiers ?? [],
                    testPlan: testSelection?.testPlan
                )
            }
        } catch {
            return
        }

        let context = TicketBuildJobAdapter.makeExecutionContext(
            workflowID: workflowID,
            stepID: stepID,
            workCycle: record.workCycle,
            workspaceID: workspaceID,
            checkoutPath: checkout,
            profile: profile,
            testSelection: testSelection,
            jobID: jobID,
            sourceFingerprint: fingerprint
        )
        _ = store.dispatch(
            .startStepAction(
                StartStepAction(
                    eventID: UUID(),
                    workflowID: workflowID,
                    stepID: stepID,
                    context: context,
                    at: Date()
                )
            )
        )

        let finished = await buildCoordinator.wait(for: jobID)
        let currentFingerprint = await fingerprintService.fingerprint(checkoutPath: checkout)
        let evidence = TicketBuildJobAdapter.makeEvidence(job: finished, context: context)
        let applyEvent = TicketWorkflowResultBridge.makeApplyEvent(
            evidence: evidence,
            resultSummary: finished.resultSummary,
            currentFingerprint: currentFingerprint
        )
        _ = store.dispatch(.applyJobEvidence(applyEvent))
        if finished.state == .succeeded {
            lastSucceededJobByWorkflow[workflowID] = finished
            if let product = try? await productResolver.resolveProduct(from: finished) {
                lastBuiltProductByWorkflow[workflowID] = product
            }
        }
        await store.saveProgress()
    }

    private func runSimulator(workflowID: UUID, stepID: UUID) async {
        guard let record = store.workflows[workflowID],
              let workspaceID = record.workspaceID,
              let profileStore else { return }
        let profile = profileStore.profileOrEmpty(for: workspaceID)
        let udid = profile.simulatorUDID
        let checkout = workspaceStore?.workspace(withID: workspaceID)?.directoryPath ?? ""

        let context = TicketActionExecutionContext(
            id: UUID(),
            workflowID: workflowID,
            stepID: stepID,
            workCycle: record.workCycle,
            workspaceID: workspaceID,
            checkoutPath: checkout,
            profileFingerprint: TicketProfileFingerprint.digest(profile: profile, testSelection: nil),
            sourceFingerprint: .incomplete(),
            jobID: UUID(),
            createdAt: Date()
        )
        _ = store.dispatch(
            .startStepAction(
                StartStepAction(
                    eventID: UUID(),
                    workflowID: workflowID,
                    stepID: stepID,
                    context: context,
                    at: Date()
                )
            )
        )

        let result: TicketWorkflowSimulatorActionResult
        if let artifact = lastBuiltProductByWorkflow[workflowID] {
            result = await simulatorBridge.prepareInstallAndLaunch(
                artifact: artifact,
                selectedUDID: udid
            )
        } else if let job = lastSucceededJobByWorkflow[workflowID] {
            result = await simulatorBridge.prepareInstallAndLaunch(
                job: job,
                selectedUDID: udid
            )
        } else {
            return
        }

        // Launch success must not auto-complete manual device check.
        guard let outcome = TicketWorkflowSimulatorBridge.checklistOutcome(for: result) else {
            return
        }
        _ = store.dispatch(
            .applyJobEvidence(
                ApplyJobEvidence(
                    eventID: UUID(),
                    workflowID: workflowID,
                    stepID: stepID,
                    workCycle: record.workCycle,
                    jobID: context.jobID,
                    outcome: outcome,
                    sourceFingerprint: .incomplete(),
                    profileFingerprint: context.profileFingerprint,
                    applicability: .unverified,
                    at: Date()
                )
            )
        )
        await store.saveProgress()
    }

    private func makeCurrentJiraObservation(for workflowID: UUID) async -> TicketJiraObservation? {
        guard let record = store.workflows[workflowID] else { return nil }
        let page = JiraWebSession.shared.page
        let generation = store.runtimeContext[workflowID]?.navigationGeneration ?? 0
        let extraction = await JiraDetailStatusExtractor.extract(
            from: page,
            navigationGeneration: generation
        )

        var observedToken: TicketAssociationToken?
        if case let .matched(detail) = extraction {
            observedToken = try? await store.makeAssociationToken(
                originHost: detail.originHost,
                issueKey: detail.issueKey
            )
        }

        return TicketJiraObservationBuilder.makeObservation(
            extraction: extraction,
            expectedAssociation: record.association,
            observedAssociation: observedToken,
            navigationGeneration: generation,
            isFromVisibleIssuePage: true
        )
    }

    private func memoryStatusLabel(from observation: TicketJiraObservation) -> String? {
        if case let .matched(detail) = observation.extraction {
            return detail.statusLabel
        }
        return nil
    }

    private func attachObservedStatus(
        workflowID: UUID,
        status: String,
        observation: TicketJiraObservation
    ) {
        let existing = store.runtimeContext[workflowID]
        var key = existing?.displayKey ?? "Tracked ticket"
        var title = existing?.displayTitle
        var url = existing?.issueURL
        if case let .matched(detail) = observation.extraction {
            key = detail.issueKey
            url = detail.pageURL
        }
        _ = store.dispatch(
            .attachRuntimeContext(
                AttachRuntimeContext(
                    eventID: UUID(),
                    workflowID: workflowID,
                    displayKey: key,
                    displayTitle: title,
                    observedStatus: status,
                    issueURL: url,
                    navigationGeneration: observation.navigationGeneration,
                    at: Date()
                )
            )
        )
    }

    private func openInJira(workflowID: UUID) {
        if let url = store.runtimeContext[workflowID]?.issueURL {
            JiraDeepLink.shared.set(url: url)
        }
        ConsoleNavigation.show(.jira)
    }

    private func commitTemplate(_ template: TicketWorkflowTemplate) {
        store.upsertTemplate(template)
        Task { await store.saveProgress() }
    }
}
