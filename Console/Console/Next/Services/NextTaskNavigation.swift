import Foundation

/// Pure Next-card navigation: verify the chosen candidate still exists, then
/// either open that exact item or fall back to Refresh/Open source. Never
/// substitutes a different session, ticket, or merge request.
enum NextTaskNavigation {
    struct Plan: Equatable, Sendable {
        var destination: SidebarSelection
        var jiraIssueURL: URL? = nil
        var mergeRequestURL: URL? = nil
        var mergeRequestKind: CodeHostListKind? = nil
        var sessionID: UUID? = nil
        var workflowID: UUID? = nil
        var stepID: UUID? = nil
        var clearSessionSelection: Bool = false
    }

    enum Decision: Equatable, Sendable {
        case navigate(Plan)
        case stay(updatedTask: NextTask)
    }

    static func decide(
        task: NextTask,
        snapshot: NextContextSnapshot,
        liveSessionStates: [UUID: DisplayedSessionState]
    ) -> Decision {
        switch task.resolvedOpenTarget {
        case .mergeRequest(let url, let list):
            let items = list == .reviewsRequested ? snapshot.reviewItems : snapshot.authoredItems
            if items.contains(where: { $0.mergeRequestURL == url || $0.id == url }) {
                return .navigate(Plan(
                    destination: .mergeRequests,
                    mergeRequestURL: url,
                    mergeRequestKind: list
                ))
            }
            return .stay(updatedTask: missingItemTask(
                kind: task.kind,
                source: list == .reviewsRequested ? .reviews : .authored,
                subject: "merge request"
            ))

        case .jiraIssue(let key, let url):
            let stillPresent = snapshot.tickets.contains { ticket in
                ticket.issueURL == url || (!key.isEmpty && ticket.key == key)
            }
            if stillPresent {
                return .navigate(Plan(
                    destination: .jira,
                    jiraIssueURL: url
                ))
            }
            return .stay(updatedTask: missingItemTask(
                kind: .newTicket,
                source: .jira,
                subject: "ticket"
            ))

        case .session(let id):
            if sessionStillActionable(id: id, live: liveSessionStates) {
                return .navigate(Plan(
                    destination: .sessions,
                    sessionID: id
                ))
            }
            return .stay(updatedTask: missingSessionTask())

        case .ticketWorkflow(let workflowID, let stepID):
            let stillPresent = snapshot.workflowSteps.contains {
                $0.workflowID == workflowID && $0.stepID == stepID && !$0.isBlocked
            }
            if stillPresent {
                return .navigate(Plan(
                    destination: .ticketWork,
                    workflowID: workflowID,
                    stepID: stepID
                ))
            }
            return .stay(updatedTask: NextTask(
                kind: .ticketWorkflowStep,
                headline: "That workflow step is no longer actionable",
                lines: ["Open Ticket Work to pick the next step."],
                openTarget: .source(.jira)
            ))

        case .source(let kind):
            return .navigate(sourcePlan(kind))
        }
    }

    static func sessionStillActionable(
        id: UUID,
        live: [UUID: DisplayedSessionState]
    ) -> Bool {
        guard let state = live[id] else { return false }
        return HomeSessionsPresentation.needsYou(state)
    }

    static func sourcePlan(_ kind: NextSourceKind) -> Plan {
        switch kind {
        case .reviews:
            return Plan(destination: .mergeRequests, mergeRequestKind: .reviewsRequested)
        case .authored:
            return Plan(destination: .mergeRequests, mergeRequestKind: .authored)
        case .jira:
            return Plan(destination: .jira)
        case .sessions:
            return Plan(destination: .sessions, clearSessionSelection: true)
        }
    }

    private static func missingItemTask(
        kind: NextTaskKind,
        source: NextSourceKind,
        subject: String
    ) -> NextTask {
        NextTask(
            kind: kind,
            headline: "That \(subject) is no longer in the list",
            lines: [
                "Refresh to pick the next task, or open the source."
            ],
            openTarget: .source(source)
        )
    }

    private static func missingSessionTask() -> NextTask {
        NextTask(
            kind: .sessionAttention,
            headline: "That session is no longer available",
            lines: [
                "Refresh to pick the next task, or open Sessions."
            ],
            openTarget: .source(.sessions)
        )
    }
}
