import Foundation
import SwiftUI
import WebKit

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

    /// Starts both lists, or reloads them if they already completed. First
    /// load is not doubled. Returns after both controllers settle or
    /// `timeout` elapses. Never throws — callers read whatever items survived.
    func refreshBoth(timeout: TimeInterval = 10) async {
        for kind in CodeHostListKind.allCases {
            controller(for: kind).startOrRefresh()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let busy = CodeHostListKind.allCases.contains { controller(for: $0).isRefreshing }
            if !busy { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// The scheduled reviews-requested scan cycle used by
    /// `MRReviewScanScheduler`.
    ///
    /// The user's browsing of the retained GitLab page always wins over the
    /// timer: when the page has been navigated away from the configured list
    /// URL (an MR detail page, say) or is mid-navigation, the cycle defers
    /// its forced reload and only resumes pending work. Sign-in recovery is
    /// respected by the controller itself (`startOrRefresh` never reloads
    /// while a sign-in round trip is in progress).
    func refreshReviewsList(timeout: TimeInterval = 10) async {
        let controller = controller(for: .reviewsRequested)
        guard !Task.isCancelled, !retainedReviewsPageIsAwayFromList,
              !controller.wantsAuthenticationObservation, !controller.isRefreshing else { return }
        controller.startOrRefresh()
        let generation = controller.currentGeneration
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { break }
            if !controller.isRefreshing { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        // Only cancel the extraction this scan started, never newer user work.
        if controller.currentGeneration == generation {
            controller.cancelPendingWork()
        }
    }

    /// True when the retained reviews page is interactive somewhere other
    /// than the configured list URL. Query-only differences count too —
    /// pagination and sorting are user state worth preserving.
    private var retainedReviewsPageIsAwayFromList: Bool {
        let page = CodeHostWebSessionStore.shared.page(for: .reviewsRequested)
        if page.isLoading { return true }
        guard let current = page.url else { return false }
        guard let configured = ListURLNormalization.url(
            from: CodeHostConfiguration.effectiveURLString(for: .reviewsRequested)
        ) else { return false }
        return current.absoluteString != configured.absoluteString
    }
}
