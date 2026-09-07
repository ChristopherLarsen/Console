import XCTest
@testable import Console

final class TicketWorkflowReducerTests: XCTestCase {

    private let sensitiveKey = "SENSITIVE_TICKET_KEY"
    private let sensitiveTitle = "SENSITIVE_TITLE"
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Tracking / association

    func testDuplicateTrackingSameAssociationOpensOneWorkflow() {
        var workflows: [UUID: TicketWorkflowRecord] = [:]
        var seen = Set<UUID>()
        let association = TicketAssociationToken(digest: Data([0x01, 0x02, 0x03]))
        let firstID = UUID()
        let secondID = UUID()

        let first = reduce(
            &workflows, &seen,
            .trackingStarted(makeTracking(workflowID: firstID, association: association))
        )
        XCTAssertNil(first.error)
        XCTAssertEqual(workflows.count, 1)
        XCTAssertEqual(first.record?.id, firstID)

        let second = reduce(
            &workflows, &seen,
            .trackingStarted(makeTracking(workflowID: secondID, association: association))
        )
        XCTAssertNil(second.error)
        XCTAssertEqual(workflows.count, 1)
        XCTAssertEqual(second.record?.id, firstID)
        XCTAssertNil(workflows[secondID])
    }

    func testDifferentAssociationDigestsStaySeparate() {
        var workflows: [UUID: TicketWorkflowRecord] = [:]
        var seen = Set<UUID>()
        let a = TicketAssociationToken(digest: Data([0xAA]))
        let b = TicketAssociationToken(digest: Data([0xBB]))
        let idA = UUID()
        let idB = UUID()

        _ = reduce(&workflows, &seen, .trackingStarted(makeTracking(workflowID: idA, association: a)))
        _ = reduce(&workflows, &seen, .trackingStarted(makeTracking(workflowID: idB, association: b)))

        XCTAssertEqual(workflows.count, 2)
        XCTAssertEqual(workflows[idA]?.association, a)
        XCTAssertEqual(workflows[idB]?.association, b)
    }

    func testTemplateVersionRetainedOnRecord() {
        var workflows: [UUID: TicketWorkflowRecord] = [:]
        var seen = Set<UUID>()
        let id = UUID()
        let result = reduce(
            &workflows, &seen,
            .trackingStarted(makeTracking(
                workflowID: id,
                association: TicketAssociationToken(digest: Data([0x11])),
                templateVersion: TicketWorkflowDefaultTemplate.version
            ))
        )
        XCTAssertEqual(result.record?.templateVersion, TicketWorkflowDefaultTemplate.version)
        XCTAssertEqual(result.record?.templateID, TicketWorkflowDefaultTemplate.templateID)
    }

    // MARK: - Stage gates

    func testStageRejectsUnmetRequiredGates() {
        var workflows: [UUID: TicketWorkflowRecord] = [:]
        var seen = Set<UUID>()
        let id = seedWorkflow(&workflows, &seen)

        let advance = reduce(
            &workflows, &seen,
            .advanceStage(AdvanceStage(eventID: UUID(), workflowID: id, at: now))
        )
        XCTAssertEqual(advance.error, .requiredGatesUnsatisfied)
        XCTAssertEqual(workflows[id]?.currentStage, .understand)
    }

    func testAdvanceSucceedsWhenRequiredStepsSatisfied() {
        var workflows: [UUID: TicketWorkflowRecord] = [:]
        var seen = Set<UUID>()
        let id = seedWorkflow(&workflows, &seen)
        acknowledgeUnderstand(&workflows, &seen, id: id)

        let advance = reduce(
            &workflows, &seen,
            .advanceStage(AdvanceStage(eventID: UUID(), workflowID: id, at: now))
        )
        XCTAssertNil(advance.error)
        XCTAssertEqual(workflows[id]?.currentStage, .prepare)
    }

    // MARK: - Acknowledge / skip / automated

    func testAutomatedRolesCannotBeAcknowledged() {
        var workflows: [UUID: TicketWorkflowRecord] = [:]
        var seen = Set<UUID>()
        let id = seedWorkflow(&workflows, &seen)
        guard let build = step(in: workflows[id]!, role: .buildPassed) else {
            return XCTFail("missing build step")
        }

        let result = reduce(
            &workflows, &seen,
            .acknowledgeStep(AcknowledgeStep(eventID: UUID(), workflowID: id, stepID: build.id, at: now))
        )
        XCTAssertEqual(result.error, .automatedCannotAcknowledge)
        XCTAssertEqual(workflows[id]?.steps.first { $0.role == .buildPassed }?.outcome, .pending)
    }

    func testRequiredStepCannotBeSkipped() {
        var workflows: [UUID: TicketWorkflowRecord] = [:]
        var seen = Set<UUID>()
        let id = seedWorkflow(&workflows, &seen)
        guard let scope = step(in: workflows[id]!, role: .scopeUnderstood) else {
            return XCTFail("missing scope step")
        }

        let result = reduce(
            &workflows, &seen,
            .skipStep(SkipStep(eventID: UUID(), workflowID: id, stepID: scope.id, at: now))
        )
        XCTAssertEqual(result.error, .stepNotOptional)
    }

    func testOptionalStepMayBeSkipped() {
        var workflows: [UUID: TicketWorkflowRecord] = [:]
        var seen = Set<UUID>()
        let id = seedWorkflow(&workflows, &seen)
        guard let release = step(in: workflows[id]!, role: .releaseRequirementsSatisfied) else {
            return XCTFail("missing optional step")
        }

        let result = reduce(
            &workflows, &seen,
            .skipStep(SkipStep(eventID: UUID(), workflowID: id, stepID: release.id, at: now))
        )
        XCTAssertNil(result.error)
        XCTAssertEqual(workflows[id]?.steps.first { $0.id == release.id }?.outcome, .skipped)
    }

    // MARK: - Session activity cannot satisfy verification/closure

    func testSessionActivityCannotSatisfyVerificationOrClosure() {
        var workflows: [UUID: TicketWorkflowRecord] = [:]
        var seen = Set<UUID>()
        let id = seedWorkflow(&workflows, &seen)

        _ = reduce(
            &workflows, &seen,
            .applySessionActivity(ApplySessionActivity(
                eventID: UUID(),
                workflowID: id,
                sessionID: UUID(),
                kind: .turnCompleted,
                at: now
            ))
        )

        let record = workflows[id]!
        XCTAssertEqual(record.steps.first { $0.role == .sessionsVisible }?.outcome, .succeeded)
        XCTAssertEqual(record.steps.first { $0.role == .buildPassed }?.outcome, .pending)
        XCTAssertEqual(record.steps.first { $0.role == .testsPassed }?.outcome, .pending)
        XCTAssertEqual(record.steps.first { $0.role == .selfReviewCompleted }?.outcome, .pending)
        XCTAssertEqual(record.steps.first { $0.role == .jiraClosureVerified }?.outcome, .pending)
    }

    // MARK: - Evidence

    func testDuplicateEventDoesNotMutate() {
        var workflows: [UUID: TicketWorkflowRecord] = [:]
        var seen = Set<UUID>()
        let id = seedWorkflow(&workflows, &seen)
        guard let scope = step(in: workflows[id]!, role: .scopeUnderstood) else {
            return XCTFail("missing step")
        }
        let eventID = UUID()
        let event = TicketWorkflowEvent.acknowledgeStep(
            AcknowledgeStep(eventID: eventID, workflowID: id, stepID: scope.id, at: now)
        )
        XCTAssertNil(reduce(&workflows, &seen, event).error)
        let afterFirst = workflows[id]!

        let dup = reduce(&workflows, &seen, event)
        XCTAssertEqual(dup.error, .duplicateEvent)
        XCTAssertEqual(workflows[id], afterFirst)
    }

    func testWrongWorkflowEvidenceRejected() {
        var workflows: [UUID: TicketWorkflowRecord] = [:]
        var seen = Set<UUID>()
        let id = seedWorkflow(&workflows, &seen)
        guard let build = step(in: workflows[id]!, role: .buildPassed) else {
            return XCTFail("missing build")
        }

        let result = reduce(
            &workflows, &seen,
            .applyJobEvidence(ApplyJobEvidence(
                eventID: UUID(),
                workflowID: id,
                stepID: build.id,
                workCycle: 1,
                jobID: UUID(),
                outcome: .succeeded,
                sourceFingerprint: .incomplete(at: now),
                profileFingerprint: "fp",
                applicability: .wrongWorkflow,
                at: now
            ))
        )
        XCTAssertEqual(result.error, .wrongWorkflow)
        XCTAssertNotEqual(workflows[id]?.steps.first { $0.id == build.id }?.outcome, .succeeded)
    }

    func testObsoleteCycleEvidenceCannotAdvance() {
        var workflows: [UUID: TicketWorkflowRecord] = [:]
        var seen = Set<UUID>()
        let id = seedWorkflow(&workflows, &seen)
        guard let build = step(in: workflows[id]!, role: .buildPassed) else {
            return XCTFail("missing build")
        }

        let result = reduce(
            &workflows, &seen,
            .applyJobEvidence(ApplyJobEvidence(
                eventID: UUID(),
                workflowID: id,
                stepID: build.id,
                workCycle: 99,
                jobID: UUID(),
                outcome: .succeeded,
                sourceFingerprint: completeFingerprint(),
                profileFingerprint: "fp",
                applicability: .obsoleteCycle,
                at: now
            ))
        )
        XCTAssertEqual(result.error, .evidenceNotApplicable)
        XCTAssertEqual(workflows[id]?.steps.first { $0.id == build.id }?.outcome, .pending)
    }

    func testNonCurrentApplicabilityDoesNotSucceed() {
        var workflows: [UUID: TicketWorkflowRecord] = [:]
        var seen = Set<UUID>()
        let id = seedWorkflow(&workflows, &seen)
        guard let build = step(in: workflows[id]!, role: .buildPassed) else {
            return XCTFail("missing build")
        }

        let result = reduce(
            &workflows, &seen,
            .applyJobEvidence(ApplyJobEvidence(
                eventID: UUID(),
                workflowID: id,
                stepID: build.id,
                workCycle: 1,
                jobID: UUID(),
                outcome: .succeeded,
                sourceFingerprint: .incomplete(at: now),
                profileFingerprint: "fp",
                applicability: .staleSource,
                at: now
            ))
        )
        XCTAssertNil(result.error)
        XCTAssertEqual(workflows[id]?.steps.first { $0.id == build.id }?.outcome, .unverified)
    }

    func testFailedEvidenceStaysRetryableAndDoesNotAdvance() {
        var workflows: [UUID: TicketWorkflowRecord] = [:]
        var seen = Set<UUID>()
        let id = seedWorkflow(&workflows, &seen)
        acknowledgeUnderstand(&workflows, &seen, id: id)
        _ = reduce(&workflows, &seen, .advanceStage(AdvanceStage(eventID: UUID(), workflowID: id, at: now)))
        // prepare still unmet — evidence on later stage shouldn't advance either
        guard let build = step(in: workflows[id]!, role: .buildPassed) else {
            return XCTFail("missing build")
        }
        _ = reduce(
            &workflows, &seen,
            .applyJobEvidence(ApplyJobEvidence(
                eventID: UUID(),
                workflowID: id,
                stepID: build.id,
                workCycle: 1,
                jobID: UUID(),
                outcome: .failed,
                sourceFingerprint: completeFingerprint(),
                profileFingerprint: "fp",
                applicability: .current,
                at: now
            ))
        )
        XCTAssertEqual(workflows[id]?.steps.first { $0.id == build.id }?.outcome, .failed)
        XCTAssertEqual(workflows[id]?.currentStage, .prepare)

        // Retry with success still only updates the step.
        _ = reduce(
            &workflows, &seen,
            .applyJobEvidence(ApplyJobEvidence(
                eventID: UUID(),
                workflowID: id,
                stepID: build.id,
                workCycle: 1,
                jobID: UUID(),
                outcome: .succeeded,
                sourceFingerprint: completeFingerprint(),
                profileFingerprint: "fp",
                applicability: .current,
                at: now
            ))
        )
        XCTAssertEqual(workflows[id]?.steps.first { $0.id == build.id }?.outcome, .succeeded)
        XCTAssertEqual(workflows[id]?.currentStage, .prepare)
    }

    // MARK: - Return to implementation

    func testNewImplementationCycleInvalidatesCodeDependentChecks() {
        var workflows: [UUID: TicketWorkflowRecord] = [:]
        var seen = Set<UUID>()
        let id = seedWorkflow(&workflows, &seen)

        for role in TicketWorkflowReducer.codeDependentRoles {
            setOutcome(&workflows, id: id, role: role, .succeeded)
        }
        setOutcome(&workflows, id: id, role: .implementationCompleted, .acknowledged)

        let result = reduce(
            &workflows, &seen,
            .returnToImplementation(ReturnToImplementation(eventID: UUID(), workflowID: id, at: now))
        )
        XCTAssertNil(result.error)
        let record = workflows[id]!
        XCTAssertEqual(record.workCycle, 2)
        XCTAssertEqual(record.currentStage, .implement)
        for role in TicketWorkflowReducer.codeDependentRoles {
            XCTAssertEqual(
                record.steps.first { $0.role == role }?.outcome,
                .pending,
                "\(role) should reset"
            )
        }
        XCTAssertEqual(
            record.steps.first { $0.role == .implementationCompleted }?.outcome,
            .acknowledged
        )
    }

    // MARK: - Blockers

    func testBlockedLifecycleRejectsAdvanceAndClose() {
        var workflows: [UUID: TicketWorkflowRecord] = [:]
        var seen = Set<UUID>()
        let id = seedWorkflow(&workflows, &seen)
        acknowledgeUnderstand(&workflows, &seen, id: id)

        _ = reduce(
            &workflows, &seen,
            .setBlocker(SetBlocker(
                eventID: UUID(),
                workflowID: id,
                code: .waitingForReviewer,
                at: now
            ))
        )
        XCTAssertEqual(workflows[id]?.lifecycle, .blocked)

        let advance = reduce(
            &workflows, &seen,
            .advanceStage(AdvanceStage(eventID: UUID(), workflowID: id, at: now))
        )
        XCTAssertEqual(advance.error, .lifecycleBlocked)

        let close = reduce(
            &workflows, &seen,
            .closeWorkflow(CloseWorkflow(
                eventID: UUID(),
                workflowID: id,
                observation: acceptedObservation(for: workflows[id]!),
                at: now
            ))
        )
        XCTAssertEqual(close.error, .lifecycleBlocked)
    }

    // MARK: - Restart helpers

    func testMarkInterruptedOnRunningSteps() {
        var workflows: [UUID: TicketWorkflowRecord] = [:]
        var seen = Set<UUID>()
        let id = seedWorkflow(&workflows, &seen)
        guard let build = step(in: workflows[id]!, role: .buildPassed) else {
            return XCTFail("missing build")
        }
        setOutcome(&workflows, id: id, role: .buildPassed, .running)

        _ = reduce(
            &workflows, &seen,
            .markInterrupted(MarkInterrupted(
                eventID: UUID(),
                workflowID: id,
                stepIDs: [build.id],
                at: now
            ))
        )
        XCTAssertEqual(workflows[id]?.steps.first { $0.id == build.id }?.outcome, .interrupted)
    }

    func testMarkRevalidationRequiredOnAutomatedSucceededSteps() {
        var workflows: [UUID: TicketWorkflowRecord] = [:]
        var seen = Set<UUID>()
        let id = seedWorkflow(&workflows, &seen)
        guard let build = step(in: workflows[id]!, role: .buildPassed) else {
            return XCTFail("missing build")
        }
        setOutcome(&workflows, id: id, role: .buildPassed, .succeeded)

        _ = reduce(
            &workflows, &seen,
            .markRevalidationRequired(MarkRevalidationRequired(
                eventID: UUID(),
                workflowID: id,
                stepIDs: [build.id],
                at: now
            ))
        )
        XCTAssertEqual(
            workflows[id]?.steps.first { $0.id == build.id }?.outcome,
            .previouslyPassedNeedsRevalidation
        )
        XCTAssertEqual(workflows[id]?.lifecycle, .needsReconciliation)
    }

    // MARK: - Forget

    func testForgetWorkflowRemovesRecord() {
        var workflows: [UUID: TicketWorkflowRecord] = [:]
        var seen = Set<UUID>()
        let id = seedWorkflow(&workflows, &seen)

        let result = reduce(
            &workflows, &seen,
            .forgetWorkflow(ForgetWorkflow(eventID: UUID(), workflowID: id, at: now))
        )
        XCTAssertEqual(result.removedWorkflowID, id)
        XCTAssertTrue(workflows.isEmpty)
    }

    // MARK: - Closure observations

    func testClosureRejectsStaleObservation() {
        assertCloseRejected(reason: .stale) { record in
            var obs = acceptedObservation(for: record)
            obs.observedAt = now.addingTimeInterval(-120)
            return obs
        }
    }

    func testClosureRejectsWrongTicket() {
        assertCloseRejected(reason: .wrongTicket) { record in
            var obs = acceptedObservation(for: record)
            obs.observedAssociation = TicketAssociationToken(digest: Data([0xFF]))
            return obs
        }
    }

    func testClosureRejectsAuthenticationPage() {
        assertCloseRejected(reason: .authenticationPage) { _ in
            TicketJiraObservation(
                extraction: .authenticationRequired,
                expectedAssociation: TicketAssociationToken(digest: Data([0x01])),
                observedAssociation: TicketAssociationToken(digest: Data([0x01])),
                observedAt: now,
                navigationGeneration: 1,
                isFromVisibleIssuePage: true
            )
        }
    }

    func testClosureRejectsUnsupportedPage() {
        assertCloseRejected(reason: .unsupportedPage) { record in
            var obs = acceptedObservation(for: record)
            obs.extraction = .unsupportedPage
            return obs
        }
    }

    func testClosureAcceptsFreshTerminalObservationWhenGatesMet() {
        var workflows: [UUID: TicketWorkflowRecord] = [:]
        var seen = Set<UUID>()
        let id = seedWorkflow(&workflows, &seen)
        satisfyAllInternalGates(&workflows, id: id)

        let result = reduce(
            &workflows, &seen,
            .closeWorkflow(CloseWorkflow(
                eventID: UUID(),
                workflowID: id,
                observation: acceptedObservation(for: workflows[id]!),
                at: now
            ))
        )
        XCTAssertNil(result.error)
        XCTAssertEqual(workflows[id]?.lifecycle, .closed)
        XCTAssertEqual(workflows[id]?.steps.first { $0.role == .jiraClosureVerified }?.outcome, .succeeded)
    }

    // MARK: - Privacy

    func testAttachRuntimeContextDoesNotPersistSentinelsInRecord() {
        var workflows: [UUID: TicketWorkflowRecord] = [:]
        var seen = Set<UUID>()
        var runtime: [UUID: TicketWorkflowRuntimeContext] = [:]
        let id = seedWorkflow(&workflows, &seen)
        let associationDigest = workflows[id]!.association.digest

        let attach = AttachRuntimeContext(
            eventID: UUID(),
            workflowID: id,
            displayKey: sensitiveKey,
            displayTitle: sensitiveTitle,
            observedStatus: "SENSITIVE_STATUS",
            issueURL: URL(string: "https://example.invalid/browse/\(sensitiveKey)"),
            navigationGeneration: 3,
            at: now
        )
        let result = reduce(&workflows, &seen, .attachRuntimeContext(attach))
        XCTAssertNil(result.error)
        TicketWorkflowPresentation.applyRuntimeAttachment(attach, into: &runtime)

        let record = workflows[id]!
        assertRecordOmitsSentinels(record)
        XCTAssertEqual(record.association.digest, associationDigest)
        XCTAssertEqual(runtime[id]?.displayKey, sensitiveKey)
        XCTAssertEqual(runtime[id]?.displayTitle, sensitiveTitle)
    }

    func testPresentationBuilderSurfacesNextActionWithoutEmbeddingRulesInViews() {
        var workflows: [UUID: TicketWorkflowRecord] = [:]
        var seen = Set<UUID>()
        let id = seedWorkflow(&workflows, &seen)
        let runtime = TicketWorkflowRuntimeContext(
            displayKey: "SYN-1",
            displayTitle: "Synthetic",
            observedStatus: "In Progress",
            issueURL: nil,
            navigationGeneration: 1,
            updatedAt: now
        )
        let detail = TicketWorkflowPresentationBuilder.detail(
            record: workflows[id]!,
            runtime: runtime,
            terminalJiraStatus: TicketWorkflowTemplate.defaultTerminalJiraStatus,
            now: now
        )
        XCTAssertEqual(detail.nextAction?.kind, .acknowledgeStep)
        XCTAssertFalse(detail.canAdvance)
        XCTAssertEqual(detail.title, "Synthetic")
    }

    // MARK: - Helpers

    private func reduce(
        _ workflows: inout [UUID: TicketWorkflowRecord],
        _ seen: inout Set<UUID>,
        _ event: TicketWorkflowEvent
    ) -> TicketWorkflowReduceResult {
        TicketWorkflowReducer.reduce(
            workflows: &workflows,
            seenEventIDs: &seen,
            event: event,
            terminalJiraStatus: TicketWorkflowTemplate.defaultTerminalJiraStatus,
            now: now
        )
    }

    private func makeTracking(
        workflowID: UUID,
        association: TicketAssociationToken,
        templateVersion: Int = TicketWorkflowDefaultTemplate.version
    ) -> TrackingStarted {
        TrackingStarted(
            eventID: UUID(),
            workflowID: workflowID,
            association: association,
            templateID: TicketWorkflowDefaultTemplate.templateID,
            templateVersion: templateVersion,
            steps: TicketWorkflowDefaultTemplate.defaultSteps().map { TicketChecklistStepState(from: $0) },
            workspaceID: nil,
            at: now
        )
    }

    @discardableResult
    private func seedWorkflow(
        _ workflows: inout [UUID: TicketWorkflowRecord],
        _ seen: inout Set<UUID>,
        digest: UInt8 = 0x01
    ) -> UUID {
        let id = UUID()
        _ = reduce(
            &workflows, &seen,
            .trackingStarted(makeTracking(
                workflowID: id,
                association: TicketAssociationToken(digest: Data([digest]))
            ))
        )
        return id
    }

    private func step(in record: TicketWorkflowRecord, role: TicketStepRole) -> TicketChecklistStepState? {
        record.steps.first { $0.role == role }
    }

    private func acknowledgeUnderstand(
        _ workflows: inout [UUID: TicketWorkflowRecord],
        _ seen: inout Set<UUID>,
        id: UUID
    ) {
        for role: TicketStepRole in [.scopeUnderstood, .acceptanceUnderstood] {
            guard let s = step(in: workflows[id]!, role: role) else { continue }
            _ = reduce(
                &workflows, &seen,
                .acknowledgeStep(AcknowledgeStep(eventID: UUID(), workflowID: id, stepID: s.id, at: now))
            )
        }
    }

    private func setOutcome(
        _ workflows: inout [UUID: TicketWorkflowRecord],
        id: UUID,
        role: TicketStepRole,
        _ outcome: TicketStepOutcome
    ) {
        guard var record = workflows[id],
              let index = record.steps.firstIndex(where: { $0.role == role })
        else { return }
        record.steps[index].outcome = outcome
        if outcome == .succeeded || outcome == .acknowledged || outcome == .skipped {
            record.steps[index].satisfiedInCycle = record.workCycle
        }
        workflows[id] = record
    }

    private func satisfyAllInternalGates(
        _ workflows: inout [UUID: TicketWorkflowRecord],
        id: UUID
    ) {
        guard var record = workflows[id] else { return }
        for index in record.steps.indices {
            let step = record.steps[index]
            guard step.isRequired, step.role != .jiraClosureVerified else { continue }
            if TicketWorkflowReducer.automatedOnlyRoles.contains(step.role)
                || step.completionSource == .jobResult
                || step.completionSource == .sessionActivity
            {
                record.steps[index].outcome = .succeeded
            } else {
                record.steps[index].outcome = .acknowledged
            }
            record.steps[index].satisfiedInCycle = record.workCycle
        }
        record.currentStage = .close
        workflows[id] = record
    }

    private func completeFingerprint() -> TicketSourceFingerprint {
        TicketSourceFingerprint(
            headOID: "abc",
            stagedDigest: "s",
            unstagedDigest: "u",
            untrackedDigest: "t",
            isComplete: true,
            capturedAt: now
        )
    }

    private func acceptedObservation(for record: TicketWorkflowRecord) -> TicketJiraObservation {
        TicketJiraObservation(
            extraction: .matched(TicketJiraMatchedDetail(
                issueKey: "SYN-99",
                statusLabel: "Closed",
                originHost: "example.invalid",
                pageURL: URL(string: "https://example.invalid/browse/SYN-99")!,
                observedAt: now,
                navigationGeneration: 1
            )),
            expectedAssociation: record.association,
            observedAssociation: record.association,
            observedAt: now,
            navigationGeneration: 1,
            isFromVisibleIssuePage: true
        )
    }

    private func assertCloseRejected(
        reason: TicketJiraObservationRejection,
        observation: (TicketWorkflowRecord) -> TicketJiraObservation
    ) {
        var workflows: [UUID: TicketWorkflowRecord] = [:]
        var seen = Set<UUID>()
        let id = seedWorkflow(&workflows, &seen)
        satisfyAllInternalGates(&workflows, id: id)
        var obs = observation(workflows[id]!)
        // Keep expected association aligned unless the test deliberately breaks it.
        if reason != .authenticationPage {
            obs.expectedAssociation = workflows[id]!.association
        } else {
            obs.expectedAssociation = workflows[id]!.association
            // extraction already auth; still need matching expected to reach extraction switch
        }

        let result = reduce(
            &workflows, &seen,
            .closeWorkflow(CloseWorkflow(
                eventID: UUID(),
                workflowID: id,
                observation: obs,
                at: now
            ))
        )
        XCTAssertEqual(result.error, .observationRejected(reason))
        XCTAssertNotEqual(workflows[id]?.lifecycle, .closed)
    }

    private func assertRecordOmitsSentinels(_ record: TicketWorkflowRecord) {
        let blobs: [String] = [
            record.id.uuidString,
            record.association.digest.map { String(format: "%02x", $0) }.joined(),
            record.templateID.uuidString,
            "\(record.templateVersion)",
            record.lifecycle.rawValue,
            record.currentStage.rawValue,
            "\(record.workCycle)",
        ] + record.steps.flatMap { step -> [String] in
            [step.title, step.role.rawValue, step.outcome.rawValue, step.completionSource.rawValue]
        } + record.blockers.map(\.code.rawValue)
            + record.transitionHistory.map(\.code.rawValue)

        for blob in blobs {
            XCTAssertFalse(blob.contains(sensitiveKey), "record leaked key into \(blob)")
            XCTAssertFalse(blob.contains(sensitiveTitle), "record leaked title into \(blob)")
        }
    }
}
