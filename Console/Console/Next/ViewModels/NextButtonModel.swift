import Foundation
import SwiftUI

/// State machine behind the sidebar Next card: idle → checking → ready, with
/// a needs-provider hint and a failure state. The AI answer wins; any AI
/// failure falls back to the deterministic local pick so the card always
/// produces something actionable.
@MainActor
@Observable
final class NextButtonModel {
    enum Status: Equatable {
        case idle
        case checking
        case needsProvider
        case ready(NextTask, fromAI: Bool)
        case failed(String)
    }

    private(set) var status: Status = .idle
    private var checkTask: Task<Void, Never>?

    /// Runs one Check pass: refresh MR lists, snapshot everything, ask the AI.
    func check(
        sessionStore: SessionStore,
        jiraController: JiraPanelController,
        aiProviderManager: AIProviderManager?
    ) {
        guard status != .checking else { return }
        checkTask?.cancel()
        status = .checking

        guard let aiProviderManager else {
            status = .failed("AI provider is unavailable.")
            return
        }

        checkTask = Task { [weak self] in
            guard let self else { return }
            await MergeRequestListSession.shared.refreshBoth()

            if Task.isCancelled { return }

            let snapshot = Self.gatherSnapshot(
                sessionStore: sessionStore,
                jiraController: jiraController
            )

            do {
                let task = try await NextTaskService.determineNextTask(
                    snapshot: snapshot,
                    aiProviderManager: aiProviderManager
                )
                guard !Task.isCancelled else { return }
                status = .ready(task, fromAI: true)
            } catch NextTaskError.noProvider, NextTaskError.noAPIKey {
                guard !Task.isCancelled else { return }
                status = .needsProvider
            } catch {
                guard !Task.isCancelled else { return }
                status = .ready(NextContextBuilder.fallbackTask(for: snapshot), fromAI: false)
            }
        }
    }

    func cancel() {
        checkTask?.cancel()
        checkTask = nil
        if status == .checking { status = .idle }
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
