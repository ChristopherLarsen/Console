import Foundation
import SwiftUI

/// State machine behind the sidebar Next card: idle → checking → ready, with
/// a failure state. Recommendations are computed locally from the live panel
/// snapshot; panel-derived text never leaves the process.
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
    private var checkTask: Task<Void, Never>?

    /// When the last check pass was started; drives the auto-check staleness rule.
    private(set) var lastCheckStartedAt: Date?

    /// A ready answer stays valid for this long; after that a re-entry reruns it.
    static let freshnessWindow: TimeInterval = 5 * 60

    /// Production Check pass: refresh MR lists, snapshot live panels, pick locally.
    func check(
        sessionStore: SessionStore,
        jiraController: JiraPanelController
    ) {
        check(
            refresh: { await MergeRequestListSession.shared.refreshBoth() },
            snapshot: { Self.gatherSnapshot(sessionStore: sessionStore, jiraController: jiraController) }
        )
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

    func cancel() {
        checkTask?.cancel()
        checkTask = nil
        if status == .checking { status = .idle }
    }

    /// Auto-check rule for entering the Next view: run a fresh check when no
    /// task has been identified yet, or when the last check is older than the
    /// freshness window. A fresh, ready answer is left untouched.
    func checkIfNeeded(
        sessionStore: SessionStore,
        jiraController: JiraPanelController
    ) {
        checkIfNeeded(
            refresh: { await MergeRequestListSession.shared.refreshBoth() },
            snapshot: { Self.gatherSnapshot(sessionStore: sessionStore, jiraController: jiraController) }
        )
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
    static func gatherSnapshot(
        sessionStore: SessionStore,
        jiraController: JiraPanelController
    ) -> NextContextSnapshot {
        let session = MergeRequestListSession.shared
        return NextContextSnapshot(
            reviewItems: session.items(for: .reviewsRequested),
            authoredItems: session.items(for: .authored),
            sessions: sessionStore.sessions.map { session in
                NextContextSnapshot.SessionInfo(
                    name: session.name,
                    state: displayedSessionState(activity: session.activity, attention: session.attention),
                    summary: session.summary
                )
            },
            tickets: jiraController.state.tickets
        )
    }
}
