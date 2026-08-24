import Foundation
import SwiftUI

/// Process-scoped owner of the two merge-request list controllers, built on
/// the retained pages from `CodeHostWebSessionStore`.
///
/// Home's panel views previously owned their controllers, so extracted lists
/// died on every navigation away from Home. Holding the controllers here keeps
/// the last extraction alive app-wide, which lets the sidebar Next card read
/// current MR data and trigger refreshes without mounting Home.
@MainActor
final class MergeRequestListSession {
    /// The process-wide session, creating it on first use.
    static let shared = MergeRequestListSession()

    private var controllers: [CodeHostListKind: CodeHostListPanelController] = [:]

    /// The list controller for `kind`, creating it on first use. The same
    /// instance backs the Home panel and any off-screen reader (Next).
    func controller(for kind: CodeHostListKind) -> CodeHostListPanelController {
        if let existing = controllers[kind] { return existing }
        let created = CodeHostListPanelController(
            kind: kind,
            page: CodeHostWebSessionStore.shared.page(for: kind),
            configuredURLStringProvider: { CodeHostConfiguration.effectiveURLString(for: kind) }
        )
        controllers[kind] = created
        return created
    }

    /// Items retained from the last successful extraction, possibly stale.
    func items(for kind: CodeHostListKind) -> [MergeRequestSummary] {
        controller(for: kind).state.retainedItems
    }

    /// Starts both lists once and refreshes them; returns after both
    /// controllers settle or `timeout` elapses. Never throws — callers read
    /// whatever items survived.
    func refreshBoth(timeout: TimeInterval = 10) async {
        for kind in CodeHostListKind.allCases {
            controller(for: kind).startIfNeeded()
            controller(for: kind).refresh()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let busy = CodeHostListKind.allCases.contains { controller(for: $0).isRefreshing }
            if !busy { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }
}
