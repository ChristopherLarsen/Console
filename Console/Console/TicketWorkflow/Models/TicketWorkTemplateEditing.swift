import Foundation

/// Pure template-edit rules. Stages are fixed; only steps within a stage may
/// be added, renamed, reordered, toggled required, or removed (unless protected).
nonisolated enum TicketWorkTemplateEditing {
    enum EditError: Error, Equatable, Sendable {
        case stepNotFound
        case protectedStep
        case crossStageReorder
        case emptyTitle
        case stageImmutable
    }

    /// Steps belonging to `stage`, in template order.
    static func steps(in template: TicketWorkflowTemplate, stage: TicketWorkflowStage)
        -> [TicketChecklistStepTemplate]
    {
        template.steps.filter { $0.stage == stage }
    }

    static func canRemove(_ step: TicketChecklistStepTemplate) -> Bool {
        !step.isProtected && step.role != .jiraClosureVerified
    }

    /// Renames a step. Empty/whitespace titles are rejected.
    static func rename(
        _ template: inout TicketWorkflowTemplate,
        stepID: UUID,
        title: String
    ) -> EditError? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .emptyTitle }
        guard let index = template.steps.firstIndex(where: { $0.id == stepID }) else {
            return .stepNotFound
        }
        template.steps[index].title = trimmed
        return nil
    }

    /// Toggles or sets the required flag. The protected Jira closure step stays required.
    static func setRequired(
        _ template: inout TicketWorkflowTemplate,
        stepID: UUID,
        isRequired: Bool
    ) -> EditError? {
        guard let index = template.steps.firstIndex(where: { $0.id == stepID }) else {
            return .stepNotFound
        }
        let step = template.steps[index]
        if step.isProtected || step.role == .jiraClosureVerified {
            if !isRequired { return .protectedStep }
            template.steps[index].isRequired = true
            return nil
        }
        template.steps[index].isRequired = isRequired
        return nil
    }

    /// Appends a custom acknowledgement step at the end of `stage`.
    @discardableResult
    static func addStep(
        _ template: inout TicketWorkflowTemplate,
        stage: TicketWorkflowStage,
        title: String,
        isRequired: Bool = false,
        id: UUID = UUID()
    ) -> Result<UUID, EditError> {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emptyTitle) }
        let step = TicketChecklistStepTemplate(
            id: id,
            stage: stage,
            role: .custom,
            title: trimmed,
            isRequired: isRequired,
            completionSource: .developerAcknowledgement,
            isProtected: false
        )
        let insertAt = template.steps.lastIndex(where: { $0.stage == stage })
            .map { $0 + 1 }
            ?? template.steps.firstIndex(where: { $0.stage.sortIndex > stage.sortIndex })
            ?? template.steps.endIndex
        template.steps.insert(step, at: insertAt)
        return .success(id)
    }

    /// Removes a non-protected step.
    static func removeStep(
        _ template: inout TicketWorkflowTemplate,
        stepID: UUID
    ) -> EditError? {
        guard let index = template.steps.firstIndex(where: { $0.id == stepID }) else {
            return .stepNotFound
        }
        let step = template.steps[index]
        guard canRemove(step) else { return .protectedStep }
        template.steps.remove(at: index)
        return nil
    }

    /// Moves a step within its stage by `offset` (−1 up / +1 down). Cannot cross stages.
    static func moveStep(
        _ template: inout TicketWorkflowTemplate,
        stepID: UUID,
        offset: Int
    ) -> EditError? {
        guard offset == -1 || offset == 1 else { return .crossStageReorder }
        guard let globalIndex = template.steps.firstIndex(where: { $0.id == stepID }) else {
            return .stepNotFound
        }
        let step = template.steps[globalIndex]
        let stageSteps = steps(in: template, stage: step.stage)
        guard let localIndex = stageSteps.firstIndex(where: { $0.id == stepID }) else {
            return .stepNotFound
        }
        let targetLocal = localIndex + offset
        guard stageSteps.indices.contains(targetLocal) else { return .crossStageReorder }
        let targetID = stageSteps[targetLocal].id
        guard let targetGlobal = template.steps.firstIndex(where: { $0.id == targetID }) else {
            return .stepNotFound
        }
        template.steps.swapAt(globalIndex, targetGlobal)
        return nil
    }

    /// Rejects any attempt to reorder the seven fixed stages.
    static func reorderStages(_: inout TicketWorkflowTemplate) -> EditError {
        .stageImmutable
    }

    /// Bumps `version` so new tracking uses the edited checklist; existing
    /// workflows keep the version they started with.
    static func commitDraft(_ draft: TicketWorkflowTemplate) -> TicketWorkflowTemplate {
        var next = draft
        next.version = max(draft.version, 1) + 1
        return next
    }
}
