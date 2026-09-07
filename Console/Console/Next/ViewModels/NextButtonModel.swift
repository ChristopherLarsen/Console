import Foundation
import SwiftUI

/// State machine behind the Next destination card: idle → checking → ready,
/// with a failure state. Owned at app scope so the five-minute freshness
/// window survives leaving and re-entering Next. Recommendations are local
/// from the live panel snapshot; panel-derived text never leaves the process.
@MainActor
@Observable
final class NextButtonModel {
    enum Status: Equatable {
        case idle
        case checking
        case ready(NextTask, fromAI: Bool)
        case failed(String)
    }

    private(set) var status: Status = .idle
    /// How many Check passes actually started. Ignored calls (already checking)
    /// do not increment this.
    private(set) var checkStartCount = 0

    @ObservationIgnored
    private var checkTask: Task<Void, Never>?

    /// Optional production-check overrides (UI tests / previews). When nil,
    /// Check refreshes live MR lists and snapshots the live panels.
    @ObservationIgnored
    var refreshHandler: (@MainActor () async -> Void)?
    @ObservationIgnored
    var snapshotHandler: (@MainActor () -> NextContextSnapshot)?
    /// Optional Open override so unit tests can observe the plan without
    /// loading retained WebViews.
    @ObservationIgnored
    var applyPlanHandler: (@MainActor (NextTaskNavigation.Plan) -> Void)?

    /// Snapshot provider from the last Check pass, reused to verify Open
    /// against current list contents without starting another refresh.
    @ObservationIgnored
    private var lastSnapshotProvider: (@MainActor () -> NextContextSnapshot)?

    /// When the last check pass was started; drives the auto-check staleness rule.
    private(set) var lastCheckStartedAt: Date?

    /// A ready answer stays valid for this long; after that a re-entry reruns it.
    static let freshnessWindow: TimeInterval = 5 * 60

    var isChecking: Bool {
        if case .checking = status { return true }
        return false
    }

    /// Production Check pass: refresh MR lists, snapshot live panels, pick locally.
    /// A missing `sessionStore` contributes no sessions; a placeholder store is
    /// never created.
    func check(
        sessionStore: SessionStore?,
        jiraController: JiraPanelController,
        ticketWorkflowStore: TicketWorkflowStore? = nil
    ) {
        let refresh = refreshHandler ?? { await MergeRequestListSession.shared.refreshBoth() }
        let snapshot = snapshotHandler ?? {
            Self.gatherSnapshot(
                sessionStore: sessionStore,
                jiraController: jiraController,
                ticketWorkflowStore: ticketWorkflowStore
            )
        }
        check(refresh: refresh, snapshot: snapshot)
    }

    /// Testable Check pass. `llmClient` is accepted so a spy can prove Next
    /// never sends panel text; the implementation discards it.
    func check(
        refresh: @escaping @MainActor () async -> Void,
        snapshot: @escaping @MainActor () -> NextContextSnapshot,
        llmClient _: (any LLMClient)? = nil
    ) {
        guard status != .checking else { return }
        checkTask?.cancel()
        lastSnapshotProvider = snapshot
        status = .checking
        lastCheckStartedAt = Date()
        checkStartCount += 1

        checkTask = Task { [weak self] in
            guard let self else { return }
            await refresh()

            if Task.isCancelled { return }

            let snapshot = snapshot()
            let task = NextContextBuilder.recommendedTask(for: snapshot)
            guard !Task.isCancelled else { return }
            status = .ready(task, fromAI: false)
        }
    }

    /// Navigate to the ready task. Refresh never calls this. Returns the
    /// destination so SwiftUI bindings can stay in sync with `ConsoleNavigation`.
    /// Missing or no-longer-actionable targets stay on Next and offer
    /// Refresh / Open source instead of substituting another item.
    @discardableResult
    func performOpen(sessionStore: SessionStore?) -> SidebarSelection? {
        guard case .ready(let task, _) = status else { return nil }
        let snapshot = resolvedSnapshot(sessionStore: sessionStore)
        let decision = NextTaskNavigation.decide(
            task: task,
            snapshot: snapshot,
            liveSessionStates: liveSessionStates(sessionStore: sessionStore, snapshot: snapshot)
        )
        switch decision {
        case .stay(let updated):
            status = .ready(updated, fromAI: false)
            return nil
        case .navigate(let plan):
            if let applyPlanHandler {
                applyPlanHandler(plan)
            } else {
                Self.execute(plan, sessionStore: sessionStore)
            }
            return plan.destination
        }
    }

    func cancel() {
        checkTask?.cancel()
        checkTask = nil
        if status == .checking { status = .idle }
    }

    /// Auto-check rule for entering the Next view: run a fresh check when no
    /// task has been identified yet, or when the last check is older than the
    /// freshness window. A fresh, ready answer is left untouched unless its
    /// referenced session disappeared or left an actionable state.
    func checkIfNeeded(
        sessionStore: SessionStore?,
        jiraController: JiraPanelController,
        ticketWorkflowStore: TicketWorkflowStore? = nil
    ) {
        let refresh = refreshHandler ?? { await MergeRequestListSession.shared.refreshBoth() }
        let snapshot = snapshotHandler ?? {
            Self.gatherSnapshot(
                sessionStore: sessionStore,
                jiraController: jiraController,
                ticketWorkflowStore: ticketWorkflowStore
            )
        }
        checkIfNeeded(refresh: refresh, snapshot: snapshot, sessionStore: sessionStore)
    }

    func checkIfNeeded(
        refresh: @escaping @MainActor () async -> Void,
        snapshot: @escaping @MainActor () -> NextContextSnapshot,
        llmClient: (any LLMClient)? = nil,
        sessionStore: SessionStore? = nil
    ) {
        if case .ready(let task, _) = status,
           let startedAt = lastCheckStartedAt,
           Date().timeIntervalSince(startedAt) < Self.freshnessWindow {
            let current = resolvedSnapshot(sessionStore: sessionStore, provider: snapshot)
            if isCachedRecommendationValid(task, sessionStore: sessionStore, snapshot: current) {
                return
            }
            reselect(from: current)
            return
        }
        check(refresh: refresh, snapshot: snapshot, llmClient: llmClient)
    }

    /// Replaces a cached session recommendation when that session disappears
    /// or leaves an actionable state. Does not refresh remote lists.
    func invalidateCachedSessionIfNeeded(sessionStore: SessionStore?) {
        guard case .ready(let task, _) = status else { return }
        guard task.kind == .sessionAttention, let id = task.sessionID else { return }
        let snapshot = resolvedSnapshot(sessionStore: sessionStore)
        let live = liveSessionStates(sessionStore: sessionStore, snapshot: snapshot)
        guard !NextTaskNavigation.sessionStillActionable(id: id, live: live) else { return }
        reselect(from: snapshot)
    }

    // MARK: - Snapshot

    /// Pure-ish gather step; separated for clarity and future test seams.
    /// `sessionStore` may be nil — sessions are then empty rather than
    /// silently allocating a placeholder store.
    static func gatherSnapshot(
        sessionStore: SessionStore?,
        jiraController: JiraPanelController,
        ticketWorkflowStore: TicketWorkflowStore? = nil
    ) -> NextContextSnapshot {
        let session = MergeRequestListSession.shared
        let reviewsController = session.controller(for: .reviewsRequested)
        let authoredController = session.controller(for: .authored)
        let sessions: [NextContextSnapshot.SessionInfo]
        if let sessionStore {
            sessions = sessionStore.sessions.map { session in
                NextContextSnapshot.SessionInfo(
                    id: session.id,
                    name: session.name,
                    state: displayedSessionState(activity: session.activity, attention: session.attention),
                    summary: session.summary
                )
            }
        } else {
            sessions = []
        }
        let workflowSteps = ticketWorkflowStore.map(Self.workflowSteps(from:)) ?? []
        return NextContextSnapshot(
            reviewItems: reviewsController.state.retainedItems,
            authoredItems: authoredController.state.retainedItems,
            sessions: sessions,
            tickets: jiraController.state.tickets,
            workflowSteps: workflowSteps,
            reviewsStatus: NextSourceStatus.from(reviewsController.state),
            authoredStatus: NextSourceStatus.from(authoredController.state),
            ticketsStatus: NextSourceStatus.from(jiraController.state)
        )
    }

    private static func workflowSteps(
        from store: TicketWorkflowStore
    ) -> [NextContextSnapshot.WorkflowStepInfo] {
        store.workflows.values
            .filter { $0.lifecycle == .active || $0.lifecycle == .blocked }
            .compactMap { record -> NextContextSnapshot.WorkflowStepInfo? in
                let detail = store.detailSnapshot(id: record.id)
                guard let next = detail?.nextAction, let stepID = next.stepID else { return nil }
                return NextContextSnapshot.WorkflowStepInfo(
                    workflowID: record.id,
                    stepID: stepID,
                    stageDisplayName: record.currentStage.displayName,
                    stepTitle: next.title,
                    isBlocked: record.lifecycle == .blocked
                )
            }
            .sorted { $0.workflowID.uuidString < $1.workflowID.uuidString }
    }

    private func resolvedSnapshot(
        sessionStore: SessionStore?,
        provider: (@MainActor () -> NextContextSnapshot)? = nil
    ) -> NextContextSnapshot {
        let provider = provider ?? snapshotHandler ?? lastSnapshotProvider
        var snapshot = provider?() ?? Self.gatherSnapshot(
            sessionStore: sessionStore,
            jiraController: JiraWebSession.shared.panelController
        )
        if let sessionStore {
            snapshot.sessions = sessionStore.sessions.map { session in
                NextContextSnapshot.SessionInfo(
                    id: session.id,
                    name: session.name,
                    state: displayedSessionState(activity: session.activity, attention: session.attention),
                    summary: session.summary
                )
            }
        }
        return snapshot
    }

    private func reselect(from snapshot: NextContextSnapshot) {
        status = .ready(NextContextBuilder.recommendedTask(for: snapshot), fromAI: false)
    }

    private func liveSessionStates(
        sessionStore: SessionStore?,
        snapshot: NextContextSnapshot
    ) -> [UUID: DisplayedSessionState] {
        if let sessionStore {
            return Dictionary(uniqueKeysWithValues: sessionStore.sessions.map {
                ($0.id, displayedSessionState(activity: $0.activity, attention: $0.attention))
            })
        }
        return snapshot.liveSessionStates
    }

    private func isCachedRecommendationValid(
        _ task: NextTask,
        sessionStore: SessionStore?,
        snapshot: NextContextSnapshot
    ) -> Bool {
        guard task.kind == .sessionAttention else { return true }
        let live = liveSessionStates(sessionStore: sessionStore, snapshot: snapshot)
        switch task.resolvedOpenTarget {
        case .session(let id):
            return NextTaskNavigation.sessionStillActionable(id: id, live: live)
        default:
            return false
        }
    }

    static func execute(_ plan: NextTaskNavigation.Plan, sessionStore: SessionStore?) {
        if let url = plan.jiraIssueURL {
            JiraDeepLink.shared.set(url: url)
        }
        if let kind = plan.mergeRequestKind {
            MergeRequestDeepLink.shared.set(url: plan.mergeRequestURL, kind: kind)
        }
        if let sessionID = plan.sessionID {
            sessionStore?.select(sessionID: sessionID)
        } else if plan.clearSessionSelection {
            sessionStore?.clearSelection()
        }
        ConsoleNavigation.show(plan.destination)
    }

#if DEBUG
    /// In-process synthetic panel data and a delayed no-op refresh so UI tests
    /// can exercise Checking → Ready without a provider or live WebViews.
    func installSyntheticUITestSources() {
        let url = URL(string: "https://gitlab.example.com/synthetic/fixture/-/merge_requests/42")!
        let snapshot = NextContextSnapshot(
            reviewItems: [
                MergeRequestSummary(
                    id: url,
                    iidText: "42",
                    title: "Synthetic Next review",
                    projectDisplayName: "FixtureRepo",
                    authorDisplayName: "Fixture Author",
                    isDraft: false,
                    pipelineDisplayState: nil,
                    reviewDisplayState: nil,
                    updatedText: nil,
                    mergeRequestURL: url,
                    sourceOrder: 0
                )
            ]
        )
        refreshHandler = {
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        snapshotHandler = { snapshot }
    }
#endif
}
