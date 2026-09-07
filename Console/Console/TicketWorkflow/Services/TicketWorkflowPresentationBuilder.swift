import Foundation

/// Memory-only Jira labels/URLs keyed by workflow ID. Never persisted.
nonisolated struct TicketWorkflowRuntimeContext: Equatable, Sendable {
    var displayKey: String
    var displayTitle: String?
    var observedStatus: String?
    var issueURL: URL?
    var navigationGeneration: Int
    var updatedAt: Date
}

/// Applies `AttachRuntimeContext` into the parallel runtime map without touching
/// durable `TicketWorkflowRecord` fields.
enum TicketWorkflowPresentation {
    static func applyRuntimeAttachment(
        _ payload: AttachRuntimeContext,
        into runtime: inout [UUID: TicketWorkflowRuntimeContext]
    ) {
        runtime[payload.workflowID] = TicketWorkflowRuntimeContext(
            displayKey: payload.displayKey,
            displayTitle: payload.displayTitle,
            observedStatus: payload.observedStatus,
            issueURL: payload.issueURL,
            navigationGeneration: payload.navigationGeneration,
            updatedAt: payload.at
        )
    }

    static func removeRuntime(workflowID: UUID, from runtime: inout [UUID: TicketWorkflowRuntimeContext]) {
        runtime.removeValue(forKey: workflowID)
    }
}

/// Builds list/detail snapshots and next-action guidance. Views must not
/// reimplement advancement or closure rules.
enum TicketWorkflowPresentationBuilder {
    static func listItems(
        workflows: [TicketWorkflowRecord],
        runtime: [UUID: TicketWorkflowRuntimeContext],
        filter: TicketWorkflowFilter,
        terminalJiraStatus: String = TicketWorkflowTemplate.defaultTerminalJiraStatus,
        now: Date = Date()
    ) -> [TicketWorkflowListItemSnapshot] {
        workflows
            .filter { record in
                switch filter {
                case .active:
                    return record.lifecycle != .closed
                case .closed:
                    return record.lifecycle == .closed
                }
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { record in
                let ctx = runtime[record.id]
                let connected = ctx != nil
                let next = nextAction(
                    record: record,
                    runtime: ctx,
                    terminalJiraStatus: terminalJiraStatus,
                    now: now
                )
                return TicketWorkflowListItemSnapshot(
                    id: record.id,
                    lifecycle: record.lifecycle,
                    stage: record.currentStage,
                    title: displayTitle(record: record, runtime: ctx),
                    jiraStatusLabel: ctx?.observedStatus,
                    nextActionTitle: next?.title,
                    isConnectedToJira: connected
                )
            }
    }

    static func detail(
        record: TicketWorkflowRecord,
        runtime: TicketWorkflowRuntimeContext?,
        terminalJiraStatus: String,
        pendingObservation: TicketJiraObservation? = nil,
        now: Date = Date()
    ) -> TicketWorkflowDetailSnapshot {
        let connected = runtime != nil
        let stages = TicketWorkflowStage.allCases.map { stage in
            TicketStageProgressSnapshot(
                stage: stage,
                isCurrent: record.currentStage == stage,
                isCompleted: stage.sortIndex < record.currentStage.sortIndex
            )
        }
        let steps = record.steps.map { step in
            stepSnapshot(step, record: record)
        }
        let next = nextAction(
            record: record,
            runtime: runtime,
            terminalJiraStatus: terminalJiraStatus,
            now: now
        )
        let close = TicketWorkflowReducer.canClose(
            record,
            observation: pendingObservation,
            terminalJiraStatus: terminalJiraStatus,
            now: now
        )
        return TicketWorkflowDetailSnapshot(
            id: record.id,
            lifecycle: record.lifecycle,
            stage: record.currentStage,
            workCycle: record.workCycle,
            title: displayTitle(record: record, runtime: runtime),
            jiraStatusLabel: runtime?.observedStatus,
            isConnectedToJira: connected,
            stages: stages,
            steps: steps.filter { $0.stage == record.currentStage },
            blockers: record.blockers.filter(\.isActive).map {
                TicketBlockerSnapshot(id: $0.id, code: $0.code, createdAt: $0.createdAt)
            },
            associatedSessions: record.associatedSessionIDs.map {
                TicketSessionSnapshot(id: $0.id, sessionID: $0.sessionID, displayName: "Session")
            },
            nextAction: next,
            canAdvance: TicketWorkflowReducer.canAdvance(record),
            canReturnToImplementation: record.currentStage.sortIndex >= TicketWorkflowStage.implement.sortIndex
                && record.lifecycle != .closed,
            canClose: close.0,
            closeBlockedReason: close.1
        )
    }

    static func nextAction(
        record: TicketWorkflowRecord,
        runtime: TicketWorkflowRuntimeContext?,
        terminalJiraStatus: String,
        now: Date = Date()
    ) -> TicketNextActionSnapshot? {
        _ = terminalJiraStatus
        _ = now
        if record.lifecycle == .closed {
            return nil
        }
        if record.lifecycle == .blocked {
            return TicketNextActionSnapshot(
                title: "Resume blocker",
                kind: .resumeBlocker,
                workflowID: record.id,
                stepID: nil
            )
        }
        if runtime == nil {
            return TicketNextActionSnapshot(
                title: "Reconnect in Jira",
                kind: .reconnectInJira,
                workflowID: record.id,
                stepID: nil
            )
        }

        if let pending = record.steps.first(where: {
            $0.stage == record.currentStage && $0.isRequired && !TicketWorkflowReducer.isSatisfied($0)
        }) ?? record.steps.first(where: {
            $0.stage == record.currentStage && !TicketWorkflowReducer.isSatisfied($0)
        }) {
            return action(for: pending, workflowID: record.id)
        }

        if TicketWorkflowReducer.canAdvance(record) {
            return TicketNextActionSnapshot(
                title: "Advance to \(record.currentStage.next?.displayName ?? "next")",
                kind: .advanceStage,
                workflowID: record.id,
                stepID: nil
            )
        }

        if record.currentStage == .close {
            return TicketNextActionSnapshot(
                title: "Close workflow",
                kind: .closeWorkflow,
                workflowID: record.id,
                stepID: record.steps.first(where: { $0.role == .jiraClosureVerified })?.id
            )
        }

        return nil
    }

    // MARK: - Private

    private static func displayTitle(
        record: TicketWorkflowRecord,
        runtime: TicketWorkflowRuntimeContext?
    ) -> String {
        if let runtime {
            return runtime.displayTitle ?? runtime.displayKey
        }
        return "Tracked ticket · \(record.currentStage.displayName) · Reconnect in Jira"
    }

    private static func stepSnapshot(
        _ step: TicketChecklistStepState,
        record: TicketWorkflowRecord
    ) -> TicketStepSnapshot {
        let canAck = step.completionSource == .developerAcknowledgement
            && !TicketWorkflowReducer.automatedOnlyRoles.contains(step.role)
            && !TicketWorkflowReducer.isSatisfied(step)
            && record.lifecycle != .closed
        let canSkip = !step.isRequired
            && !TicketWorkflowReducer.isSatisfied(step)
            && record.lifecycle != .closed
        let canStart = step.completionSource == .jobResult
            && step.outcome != .running
            && record.lifecycle != .closed
            && !TicketWorkflowReducer.isSatisfied(step)
        return TicketStepSnapshot(
            id: step.id,
            stage: step.stage,
            title: step.title,
            role: step.role,
            isRequired: step.isRequired,
            outcome: step.outcome,
            completionSource: step.completionSource,
            canAcknowledge: canAck,
            canSkip: canSkip,
            canStartAction: canStart
        )
    }

    private static func action(for step: TicketChecklistStepState, workflowID: UUID) -> TicketNextActionSnapshot {
        let kind: TicketNextActionKind
        let title: String
        switch step.role {
        case .buildPassed:
            kind = .startBuild
            title = "Start build"
        case .testsPassed:
            kind = .startTests
            title = "Start tests"
        case .manualDeviceCheck:
            kind = .openSimulator
            title = "Open Simulator"
        case .jiraClosureVerified:
            kind = step.outcome == .unverified ? .checkStatusAgain : .openInJira
            title = step.outcome == .unverified ? "Check status again" : "Verify in Jira"
        case .implementationCompleted:
            kind = .confirmImplementation
            title = "Confirm implementation"
        default:
            if step.completionSource == .developerAcknowledgement || step.completionSource == .composite {
                kind = .acknowledgeStep
                title = "Acknowledge: \(step.title)"
            } else if step.completionSource == .jobResult {
                kind = .startBuild
                title = step.title
            } else {
                kind = .acknowledgeStep
                title = step.title
            }
        }
        return TicketNextActionSnapshot(
            title: title,
            kind: kind,
            workflowID: workflowID,
            stepID: step.id
        )
    }
}
