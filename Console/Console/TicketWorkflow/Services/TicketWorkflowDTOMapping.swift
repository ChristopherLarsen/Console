import Foundation

/// Maps domain records ↔ allowlisted storage DTOs.
/// Never copies ticket keys, titles, URLs, raw statuses, or session summaries.
enum TicketWorkflowDTOMapping {
    static func storeDTO(
        workflows: [UUID: TicketWorkflowRecord],
        templates: [UUID: TicketWorkflowTemplate]
    ) -> TicketWorkflowStoreDTO {
        TicketWorkflowStoreDTO(
            formatVersion: TicketWorkflowStoreDTO.currentFormatVersion,
            workflows: workflows.values
                .sorted { $0.id.uuidString < $1.id.uuidString }
                .map(recordDTO(from:)),
            templates: templates.values
                .sorted { $0.id.uuidString < $1.id.uuidString }
                .map(templateDTO(from:))
        )
    }

    static func apply(
        _ dto: TicketWorkflowStoreDTO,
        into workflows: inout [UUID: TicketWorkflowRecord],
        templates: inout [UUID: TicketWorkflowTemplate]
    ) {
        workflows = Dictionary(
            uniqueKeysWithValues: dto.workflows.map { ($0.id, record(from: $0)) }
        )
        let loadedTemplates = Dictionary(
            uniqueKeysWithValues: dto.templates.map { ($0.id, template(from: $0)) }
        )
        // Preserve default template when disk has no templates yet.
        if loadedTemplates.isEmpty {
            // keep existing `templates` (caller seeds default)
        } else {
            templates = loadedTemplates
        }
    }

    // MARK: - Record

    static func recordDTO(from record: TicketWorkflowRecord) -> TicketWorkflowRecordDTO {
        TicketWorkflowRecordDTO(
            id: record.id,
            associationDigest: record.association.digest,
            templateID: record.templateID,
            templateVersion: record.templateVersion,
            lifecycle: record.lifecycle,
            currentStage: record.currentStage,
            workCycle: record.workCycle,
            steps: record.steps.map(stepDTO(from:)),
            blockers: record.blockers.map(blockerDTO(from:)),
            associatedSessionIDs: record.associatedSessionIDs.map(\.sessionID),
            workspaceID: record.workspaceID,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            closedAt: record.closedAt,
            transitionHistory: record.transitionHistory.map(transitionDTO(from:))
        )
    }

    static func record(from dto: TicketWorkflowRecordDTO) -> TicketWorkflowRecord {
        TicketWorkflowRecord(
            id: dto.id,
            association: TicketAssociationToken(digest: dto.associationDigest),
            templateID: dto.templateID,
            templateVersion: dto.templateVersion,
            lifecycle: dto.lifecycle,
            currentStage: dto.currentStage,
            workCycle: dto.workCycle,
            steps: dto.steps.map(step(from:)),
            blockers: dto.blockers.map(blocker(from:)),
            associatedSessionIDs: dto.associatedSessionIDs.map { sessionID in
                TicketAssociatedSession(
                    id: UUID(),
                    sessionID: sessionID,
                    associatedAt: dto.updatedAt
                )
            },
            workspaceID: dto.workspaceID,
            createdAt: dto.createdAt,
            updatedAt: dto.updatedAt,
            closedAt: dto.closedAt,
            transitionHistory: dto.transitionHistory.map(transition(from:))
        )
    }

    // MARK: - Steps

    static func stepDTO(from step: TicketChecklistStepState) -> TicketChecklistStepStateDTO {
        TicketChecklistStepStateDTO(
            id: step.id,
            templateStepID: step.templateStepID,
            stage: step.stage,
            role: step.role,
            title: step.title,
            isRequired: step.isRequired,
            completionSource: step.completionSource,
            isProtected: step.isProtected,
            outcome: step.outcome,
            updatedAt: step.updatedAt,
            satisfiedInCycle: step.satisfiedInCycle
        )
    }

    static func step(from dto: TicketChecklistStepStateDTO) -> TicketChecklistStepState {
        var step = TicketChecklistStepState(
            from: TicketChecklistStepTemplate(
                id: dto.templateStepID,
                stage: dto.stage,
                role: dto.role,
                title: dto.title,
                isRequired: dto.isRequired,
                completionSource: dto.completionSource,
                isProtected: dto.isProtected
            ),
            outcome: dto.outcome
        )
        step.id = dto.id
        step.updatedAt = dto.updatedAt
        step.satisfiedInCycle = dto.satisfiedInCycle
        return step
    }

    // MARK: - Blockers / transitions / templates

    static func blockerDTO(from blocker: TicketWorkflowBlocker) -> TicketWorkflowBlockerDTO {
        TicketWorkflowBlockerDTO(
            id: blocker.id,
            code: blocker.code,
            createdAt: blocker.createdAt,
            clearedAt: blocker.clearedAt
        )
    }

    static func blocker(from dto: TicketWorkflowBlockerDTO) -> TicketWorkflowBlocker {
        TicketWorkflowBlocker(
            id: dto.id,
            code: dto.code,
            createdAt: dto.createdAt,
            clearedAt: dto.clearedAt
        )
    }

    static func transitionDTO(from transition: TicketWorkflowTransition) -> TicketWorkflowTransitionDTO {
        TicketWorkflowTransitionDTO(
            id: transition.id,
            at: transition.at,
            code: transition.code,
            stage: transition.stage,
            stepID: transition.stepID,
            workCycle: transition.workCycle
        )
    }

    static func transition(from dto: TicketWorkflowTransitionDTO) -> TicketWorkflowTransition {
        TicketWorkflowTransition(
            id: dto.id,
            at: dto.at,
            code: dto.code,
            stage: dto.stage,
            stepID: dto.stepID,
            workCycle: dto.workCycle
        )
    }

    static func templateDTO(from template: TicketWorkflowTemplate) -> TicketWorkflowTemplateDTO {
        TicketWorkflowTemplateDTO(
            id: template.id,
            version: template.version,
            displayName: template.displayName,
            terminalJiraStatus: template.terminalJiraStatus,
            steps: template.steps.map { step in
                TicketChecklistStepTemplateDTO(
                    id: step.id,
                    stage: step.stage,
                    role: step.role,
                    title: step.title,
                    isRequired: step.isRequired,
                    completionSource: step.completionSource,
                    isProtected: step.isProtected
                )
            }
        )
    }

    static func template(from dto: TicketWorkflowTemplateDTO) -> TicketWorkflowTemplate {
        TicketWorkflowTemplate(
            id: dto.id,
            version: dto.version,
            displayName: dto.displayName,
            steps: dto.steps.map { step in
                TicketChecklistStepTemplate(
                    id: step.id,
                    stage: step.stage,
                    role: step.role,
                    title: step.title,
                    isRequired: step.isRequired,
                    completionSource: step.completionSource,
                    isProtected: step.isProtected
                )
            },
            terminalJiraStatus: dto.terminalJiraStatus
        )
    }
}
