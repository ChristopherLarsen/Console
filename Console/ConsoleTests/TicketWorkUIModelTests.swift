import XCTest
@testable import Console

@MainActor
final class TicketWorkUIModelTests: XCTestCase {
    private let sensitiveKey = "SENSITIVE_TICKET_KEY"
    private let sensitiveTitle = "SENSITIVE_TITLE"
    private let sensitiveStatus = "SENSITIVE_STATUS"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Template editing rules

    func testTemplateEditorCannotRemoveProtectedJiraClosureStep() {
        var template = TicketWorkflowDefaultTemplate.make()
        let closure = template.steps.first { $0.role == .jiraClosureVerified }!
        XCTAssertTrue(closure.isProtected)
        XCTAssertEqual(
            TicketWorkTemplateEditing.removeStep(&template, stepID: closure.id),
            .protectedStep
        )
        XCTAssertTrue(template.steps.contains { $0.id == closure.id })
    }

    func testTemplateEditorCannotClearRequiredOnProtectedClosure() {
        var template = TicketWorkflowDefaultTemplate.make()
        let closure = template.steps.first { $0.role == .jiraClosureVerified }!
        XCTAssertEqual(
            TicketWorkTemplateEditing.setRequired(&template, stepID: closure.id, isRequired: false),
            .protectedStep
        )
        XCTAssertTrue(template.steps.first { $0.id == closure.id }?.isRequired == true)
    }

    func testTemplateEditorAddsRenamesReordersWithinStageOnly() {
        var template = TicketWorkflowDefaultTemplate.make()
        let stage = TicketWorkflowStage.understand
        let before = TicketWorkTemplateEditing.steps(in: template, stage: stage)
        XCTAssertEqual(before.count, 2)

        let add = TicketWorkTemplateEditing.addStep(&template, stage: stage, title: "Extra note")
        guard case .success(let newID) = add else {
            return XCTFail("add failed: \(add)")
        }

        XCTAssertNil(TicketWorkTemplateEditing.rename(&template, stepID: newID, title: "Renamed note"))
        XCTAssertEqual(template.steps.first { $0.id == newID }?.title, "Renamed note")

        // Move to top within stage.
        XCTAssertNil(TicketWorkTemplateEditing.moveStep(&template, stepID: newID, offset: -1))
        XCTAssertNil(TicketWorkTemplateEditing.moveStep(&template, stepID: newID, offset: -1))
        let after = TicketWorkTemplateEditing.steps(in: template, stage: stage)
        XCTAssertEqual(after.first?.id, newID)
        XCTAssertTrue(after.allSatisfy { $0.stage == stage })

        // Cannot move past stage boundary.
        XCTAssertEqual(
            TicketWorkTemplateEditing.moveStep(&template, stepID: newID, offset: -1),
            .crossStageReorder
        )
    }

    func testTemplateEditorRejectsEmptyTitleAndStageReorder() {
        var template = TicketWorkflowDefaultTemplate.make()
        let stepID = template.steps[0].id
        XCTAssertEqual(
            TicketWorkTemplateEditing.rename(&template, stepID: stepID, title: "   "),
            .emptyTitle
        )
        XCTAssertEqual(TicketWorkTemplateEditing.reorderStages(&template), .stageImmutable)

        switch TicketWorkTemplateEditing.addStep(&template, stage: .prepare, title: "") {
        case .failure(.emptyTitle):
            break
        default:
            XCTFail("expected emptyTitle")
        }
    }

    func testTemplateCommitBumpsVersion() {
        let template = TicketWorkflowDefaultTemplate.make()
        let committed = TicketWorkTemplateEditing.commitDraft(template)
        XCTAssertEqual(committed.version, template.version + 1)
        XCTAssertEqual(committed.id, template.id)
    }

    func testTemplateEditorViewModelSurfacesRules() {
        let model = TicketWorkTemplateEditorViewModel(
            template: TicketWorkflowDefaultTemplate.make(),
            handlers: TicketWorkActionHandlers()
        )
        let closure = model.draft.steps.first { $0.role == .jiraClosureVerified }!
        XCTAssertFalse(model.canRemove(closure))
        model.remove(stepID: closure.id)
        XCTAssertEqual(model.lastError, .protectedStep)
        model.attemptReorderStages()
        XCTAssertEqual(model.lastError, .stageImmutable)

        model.selectStage(.deliver)
        model.newStepTitle = "Ship checklist"
        model.addStep()
        XCTAssertNil(model.lastError)
        XCTAssertTrue(model.isDirty)
        XCTAssertTrue(model.stepsInSelectedStage.contains { $0.title == "Ship checklist" })
    }

    // MARK: - List / detail view models

    func testListFilterAndGenericDisconnectedTitle() {
        let store = TicketWorkflowStore()
        let workflowID = seedWorkflow(store: store)
        let list = TicketWorkListViewModel(store: store)

        XCTAssertEqual(list.items.count, 1)
        XCTAssertTrue(list.items[0].title.contains("Reconnect in Jira"))
        XCTAssertFalse(list.items[0].isConnectedToJira)
        XCTAssertEqual(
            list.items[0].id.uuidString,
            workflowID.uuidString
        )

        // Privacy: AX ids are UUID-based, never issue keys.
        let rowID = TicketWorkflowAccessibility.workflowRow(workflowID)
        XCTAssertFalse(rowID.contains(sensitiveKey))
        XCTAssertTrue(rowID.contains(workflowID.uuidString))

        list.setFilter(.closed)
        XCTAssertTrue(list.items.isEmpty)
    }

    func testDetailSeparatesJiraStatusAndConsoleStage() throws {
        let store = TicketWorkflowStore()
        let workflowID = seedWorkflow(store: store)
        _ = store.dispatch(.attachRuntimeContext(AttachRuntimeContext(
            eventID: UUID(),
            workflowID: workflowID,
            displayKey: sensitiveKey,
            displayTitle: sensitiveTitle,
            observedStatus: sensitiveStatus,
            issueURL: nil,
            navigationGeneration: 1,
            at: now
        )))

        let detail = TicketWorkDetailViewModel(workflowID: workflowID, store: store, handlers: TicketWorkActionHandlers())
        let snap = try XCTUnwrap(detail.snapshot)
        XCTAssertEqual(snap.title, sensitiveTitle)
        XCTAssertEqual(snap.jiraStatusLabel, sensitiveStatus)
        XCTAssertEqual(snap.stage, .understand)
        XCTAssertEqual(snap.stages.count, 7)
        XCTAssertNotNil(snap.nextAction)
        XCTAssertTrue(detail.results.isEmpty)
    }

    func testDetailNextActionAndHandlers() {
        let store = TicketWorkflowStore()
        let workflowID = seedWorkflow(store: store)
        _ = store.dispatch(.attachRuntimeContext(AttachRuntimeContext(
            eventID: UUID(),
            workflowID: workflowID,
            displayKey: "SYN-1",
            displayTitle: "Synthetic",
            observedStatus: "In Progress",
            issueURL: nil,
            navigationGeneration: 1,
            at: now
        )))

        var acknowledged: (UUID, UUID)?
        var handlers = TicketWorkActionHandlers()
        handlers.acknowledge = { wf, step in acknowledged = (wf, step) }

        let detail = TicketWorkDetailViewModel(
            workflowID: workflowID,
            store: store,
            handlers: handlers
        )
        detail.performNextAction()
        XCTAssertEqual(acknowledged?.0, workflowID)
        XCTAssertNotNil(acknowledged?.1)
    }

    func testResultsSlotAcceptsPresentationModels() {
        let store = TicketWorkflowStore()
        let workflowID = seedWorkflow(store: store)
        let resultID = UUID()
        let detail = TicketWorkDetailViewModel(
            workflowID: workflowID,
            store: store,
            handlers: TicketWorkActionHandlers(),
            resultsProvider: { id in
                guard id == workflowID else { return [] }
                return [
                    TicketWorkResultsPresentation(
                        id: resultID,
                        headline: "Build failed",
                        detailLines: ["file.swift:12"],
                        outcome: .failed
                    )
                ]
            }
        )
        XCTAssertEqual(detail.results.count, 1)
        XCTAssertEqual(detail.results[0].id, resultID)
        let ax = "TicketWorkResult.\(resultID.uuidString)"
        XCTAssertFalse(ax.contains(sensitiveKey))
    }

    func testTrackWorkAccessibilityIdentifierIsStable() {
        XCTAssertEqual(TicketWorkflowAccessibility.trackWorkButton, "TicketWorkTrack")
        XCTAssertEqual(TicketWorkflowAccessibility.list, "TicketWorkList")
        XCTAssertEqual(TicketWorkflowAccessibility.detail, "TicketWorkDetail")
    }

    // MARK: - Helpers

    @discardableResult
    private func seedWorkflow(store: TicketWorkflowStore) -> UUID {
        let id = UUID()
        let tracking = TrackingStarted(
            eventID: UUID(),
            workflowID: id,
            association: TicketAssociationToken(digest: Data([0x42])),
            templateID: TicketWorkflowDefaultTemplate.templateID,
            templateVersion: TicketWorkflowDefaultTemplate.version,
            steps: TicketWorkflowDefaultTemplate.defaultSteps().map { TicketChecklistStepState(from: $0) },
            workspaceID: nil,
            at: now
        )
        _ = store.dispatch(.trackingStarted(tracking), now: now)
        return id
    }
}
