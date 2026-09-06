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
        jiraController: JiraPanelController
    ) {
        let refresh = refreshHandler ?? { await MergeRequestListSession.shared.refreshBoth() }
        let snapshot = snapshotHandler ?? {
            Self.gatherSnapshot(sessionStore: sessionStore, jiraController: jiraController)
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
    @discardableResult
    func performOpen(sessionStore: SessionStore?) -> SidebarSelection? {
        guard case .ready(let task, _) = status else { return nil }
        switch task.kind {
        case .reviewMergeRequest, .addressComments:
            if let url = task.targetURL {
                let kind: CodeHostListKind = task.kind == .reviewMergeRequest
                    ? .reviewsRequested
                    : .authored
                MergeRequestDeepLink.shared.set(url: url, kind: kind)
                ConsoleNavigation.show(.mergeRequests)
                return .mergeRequests
            }
            openSession(task, sessionStore: sessionStore)
            return .sessions

        case .sessionAttention:
            openSession(task, sessionStore: sessionStore)
            return .sessions

        case .newTicket:
            ConsoleNavigation.show(.jira)
            return .jira
        }
    }

    private func openSession(_ task: NextTask, sessionStore: SessionStore?) {
        if let name = task.sessionName,
           let sessionStore,
           let session = sessionStore.sessions.first(where: { $0.name == name }) {
            sessionStore.select(sessionID: session.id)
        }
        ConsoleNavigation.showSessions()
    }

    func cancel() {
        checkTask?.cancel()
        checkTask = nil
        if status == .checking { status = .idle }
    }

    /// Auto-check rule for entering the Next view: run a fresh check when no
    /// task has been identified yet, or when the last check is older than the
    /// freshness window. A fresh, ready answer is left untouched.
    func checkIfNeeded(
        sessionStore: SessionStore?,
        jiraController: JiraPanelController
    ) {
        let refresh = refreshHandler ?? { await MergeRequestListSession.shared.refreshBoth() }
        let snapshot = snapshotHandler ?? {
            Self.gatherSnapshot(sessionStore: sessionStore, jiraController: jiraController)
        }
        checkIfNeeded(refresh: refresh, snapshot: snapshot)
    }

    func checkIfNeeded(
        refresh: @escaping @MainActor () async -> Void,
        snapshot: @escaping @MainActor () -> NextContextSnapshot,
        llmClient: (any LLMClient)? = nil
    ) {
        if case .ready = status,
           let startedAt = lastCheckStartedAt,
           Date().timeIntervalSince(startedAt) < Self.freshnessWindow {
            return
        }
        check(refresh: refresh, snapshot: snapshot, llmClient: llmClient)
    }

    // MARK: - Snapshot

    /// Pure-ish gather step; separated for clarity and future test seams.
    /// `sessionStore` may be nil — sessions are then empty rather than
    /// silently allocating a placeholder store.
    static func gatherSnapshot(
        sessionStore: SessionStore?,
        jiraController: JiraPanelController
    ) -> NextContextSnapshot {
        let session = MergeRequestListSession.shared
        let sessions: [NextContextSnapshot.SessionInfo]
        if let sessionStore {
            sessions = sessionStore.sessions.map { session in
                NextContextSnapshot.SessionInfo(
                    name: session.name,
                    state: displayedSessionState(activity: session.activity, attention: session.attention),
                    summary: session.summary
                )
            }
        } else {
            sessions = []
        }
        return NextContextSnapshot(
            reviewItems: session.items(for: .reviewsRequested),
            authoredItems: session.items(for: .authored),
            sessions: sessions,
            tickets: jiraController.state.tickets
        )
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
