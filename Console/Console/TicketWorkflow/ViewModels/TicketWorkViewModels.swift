import Foundation
import Observation

/// Closure bag lead wires to `TicketWorkflowCoordinating` (or stubs in tests).
@MainActor
struct TicketWorkActionHandlers {
    var acknowledge: (UUID, UUID) -> Void = { _, _ in }
    var skip: (UUID, UUID) -> Void = { _, _ in }
    var startStepAction: (UUID, UUID) -> Void = { _, _ in }
    var advance: (UUID) -> Void = { _ in }
    var returnToImplementation: (UUID) -> Void = { _ in }
    var block: (UUID, TicketBlockerCode) -> Void = { _, _ in }
    var resume: (UUID, UUID) -> Void = { _, _ in }
    var forget: (UUID) -> Void = { _ in }
    var close: (UUID) -> Void = { _ in }
    var openInJira: (UUID) -> Void = { _ in }
    var checkStatus: (UUID) -> Void = { _ in }
    var reconnectInJira: (UUID) -> Void = { _ in }
    var selectSession: (UUID) -> Void = { _ in }
    var commitTemplate: (TicketWorkflowTemplate) -> Void = { _ in }
}

@MainActor
@Observable
final class TicketWorkListViewModel {
    private(set) var filter: TicketWorkflowFilter = .active
    var selectedWorkflowID: UUID?

    @ObservationIgnored
    private let store: TicketWorkflowStore

    init(store: TicketWorkflowStore) {
        self.store = store
    }

    var items: [TicketWorkflowListItemSnapshot] {
        store.listSnapshots(filter: filter)
    }

    func setFilter(_ filter: TicketWorkflowFilter) {
        self.filter = filter
        if let selectedWorkflowID,
           !items.contains(where: { $0.id == selectedWorkflowID }) {
            self.selectedWorkflowID = nil
        }
    }

    func select(_ id: UUID?) {
        selectedWorkflowID = id
    }
}

@MainActor
@Observable
final class TicketWorkDetailViewModel {
    let workflowID: UUID

    @ObservationIgnored
    private let store: TicketWorkflowStore
    @ObservationIgnored
    private let handlers: TicketWorkActionHandlers
    @ObservationIgnored
    private let resultsProvider: (UUID) -> [TicketWorkResultsPresentation]

    var pendingBlockerCode: TicketBlockerCode = .waitingForInformation

    init(
        workflowID: UUID,
        store: TicketWorkflowStore,
        handlers: TicketWorkActionHandlers,
        resultsProvider: @escaping (UUID) -> [TicketWorkResultsPresentation] = { _ in [] }
    ) {
        self.workflowID = workflowID
        self.store = store
        self.handlers = handlers
        self.resultsProvider = resultsProvider
    }

    var snapshot: TicketWorkflowDetailSnapshot? {
        store.detailSnapshot(id: workflowID)
    }

    var results: [TicketWorkResultsPresentation] {
        resultsProvider(workflowID)
    }

    func performNextAction() {
        guard let next = snapshot?.nextAction else { return }
        switch next.kind {
        case .acknowledgeStep, .confirmImplementation:
            if let stepID = next.stepID {
                handlers.acknowledge(workflowID, stepID)
            }
        case .startBuild, .startTests, .openSimulator:
            if let stepID = next.stepID {
                handlers.startStepAction(workflowID, stepID)
            }
        case .openInJira:
            handlers.openInJira(workflowID)
        case .checkStatusAgain:
            handlers.checkStatus(workflowID)
        case .advanceStage:
            handlers.advance(workflowID)
        case .closeWorkflow:
            handlers.close(workflowID)
        case .resumeBlocker:
            if let blockerID = snapshot?.blockers.first?.id {
                handlers.resume(workflowID, blockerID)
            }
        case .reconnectInJira:
            handlers.reconnectInJira(workflowID)
        }
    }

    func acknowledge(stepID: UUID) { handlers.acknowledge(workflowID, stepID) }
    func skip(stepID: UUID) { handlers.skip(workflowID, stepID) }
    func startAction(stepID: UUID) { handlers.startStepAction(workflowID, stepID) }
    func advance() { handlers.advance(workflowID) }
    func returnToImplementation() { handlers.returnToImplementation(workflowID) }
    func block() { handlers.block(workflowID, pendingBlockerCode) }
    func resume(blockerID: UUID) { handlers.resume(workflowID, blockerID) }
    func forget() { handlers.forget(workflowID) }
    func close() { handlers.close(workflowID) }
}

@MainActor
@Observable
final class TicketWorkTemplateEditorViewModel {
    private(set) var draft: TicketWorkflowTemplate
    private(set) var selectedStage: TicketWorkflowStage = .understand
    private(set) var lastError: TicketWorkTemplateEditing.EditError?
    var newStepTitle: String = ""
    /// In-progress title edits keyed by step id (committed via `commitRename`).
    var renameDrafts: [UUID: String] = [:]

    @ObservationIgnored
    private let handlers: TicketWorkActionHandlers
    @ObservationIgnored
    private let original: TicketWorkflowTemplate

    init(template: TicketWorkflowTemplate, handlers: TicketWorkActionHandlers) {
        self.draft = template
        self.original = template
        self.handlers = handlers
    }

    var stepsInSelectedStage: [TicketChecklistStepTemplate] {
        TicketWorkTemplateEditing.steps(in: draft, stage: selectedStage)
    }

    var isDirty: Bool {
        draft.steps != original.steps
            || draft.displayName != original.displayName
            || draft.terminalJiraStatus != original.terminalJiraStatus
    }

    func selectStage(_ stage: TicketWorkflowStage) {
        selectedStage = stage
        lastError = nil
    }

    func renameDraft(for step: TicketChecklistStepTemplate) -> String {
        renameDrafts[step.id] ?? step.title
    }

    func setRenameDraft(stepID: UUID, title: String) {
        renameDrafts[stepID] = title
    }

    func commitRename(stepID: UUID) {
        let title = renameDrafts[stepID] ?? draft.steps.first(where: { $0.id == stepID })?.title ?? ""
        lastError = TicketWorkTemplateEditing.rename(&draft, stepID: stepID, title: title)
        if lastError == nil {
            renameDrafts[stepID] = nil
        }
    }

    func rename(stepID: UUID, title: String) {
        lastError = TicketWorkTemplateEditing.rename(&draft, stepID: stepID, title: title)
        renameDrafts[stepID] = nil
    }

    func setRequired(stepID: UUID, isRequired: Bool) {
        lastError = TicketWorkTemplateEditing.setRequired(&draft, stepID: stepID, isRequired: isRequired)
    }

    func addStep() {
        switch TicketWorkTemplateEditing.addStep(&draft, stage: selectedStage, title: newStepTitle) {
        case .success:
            newStepTitle = ""
            lastError = nil
        case .failure(let error):
            lastError = error
        }
    }

    func remove(stepID: UUID) {
        lastError = TicketWorkTemplateEditing.removeStep(&draft, stepID: stepID)
    }

    func moveUp(stepID: UUID) {
        lastError = TicketWorkTemplateEditing.moveStep(&draft, stepID: stepID, offset: -1)
    }

    func moveDown(stepID: UUID) {
        lastError = TicketWorkTemplateEditing.moveStep(&draft, stepID: stepID, offset: 1)
    }

    /// Always fails — stages are fixed.
    func attemptReorderStages() {
        lastError = TicketWorkTemplateEditing.reorderStages(&draft)
    }

    func canRemove(_ step: TicketChecklistStepTemplate) -> Bool {
        TicketWorkTemplateEditing.canRemove(step)
    }

    func commit() {
        let committed = TicketWorkTemplateEditing.commitDraft(draft)
        draft = committed
        handlers.commitTemplate(committed)
        lastError = nil
    }
}
