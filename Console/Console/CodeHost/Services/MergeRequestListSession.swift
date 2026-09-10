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
    let dispositions = MRReviewDispositionController()

    /// The list controller for `kind`, creating it on first use. The same
    /// instance backs the Home panel and any off-screen reader (Next).
    func controller(for kind: CodeHostListKind) -> CodeHostListPanelController {
        if let existing = controllers[kind] { return existing }
        let created = CodeHostListPanelController(
            kind: kind,
            page: CodeHostWebSessionStore.shared.page(for: kind),
            configuredURLStringProvider: { CodeHostConfiguration.effectiveURLString(for: kind) }
        )
        if kind == .reviewsRequested {
            created.onExtractionStarted = { [weak self] in self?.dispositions.reset() }
            created.onItemsExtracted = { [weak self] items in self?.dispositions.update(items) }
        }
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

    /// Reviews-requested scan cycle. Background requests defer to browsing;
    /// explicit refresh returns to the configured list. Sign-in is preserved.
    @discardableResult
    func refreshReviewsList(trigger: MRReviewScanTrigger = .background, timeout: TimeInterval = 30) async -> MRReviewScanOutcome {
        let controller = controller(for: .reviewsRequested)
        return await Self.refreshReviewsList(
            controller: controller,
            trigger: trigger,
            pageIsAwayFromList: retainedReviewsPageIsAwayFromList,
            timeout: timeout
        )
    }

    /// Manual checks return to the configured list. Background checks alone
    /// defer to browsing. Neither interrupts a recognized sign-in round trip.
    static func refreshReviewsList(
        controller: CodeHostListPanelController,
        trigger: MRReviewScanTrigger,
        pageIsAwayFromList: Bool,
        timeout: TimeInterval = 30
    ) async -> MRReviewScanOutcome {
        guard !Task.isCancelled else { return .cancelled }
        if controller.wantsAuthenticationObservation { return .signInRequired }
        if !controller.isRefreshing {
            if trigger == .background, pageIsAwayFromList { return .deferred }
            controller.startOrRefresh()
        }
        // Join a first load already started by Home rather than silently
        // skipping it or cancelling/restarting the same request.
        let generation = controller.currentGeneration
        let deadline = Date().addingTimeInterval(timeout)
        while controller.isRefreshing, Date() < deadline {
            if Task.isCancelled {
                // This task may have joined Home's first load. Cancelling a
                // timer/settings wait must not suspend that shared work;
                // the controller owns its own deadline and recovery state.
                return .cancelled
            }
            if controller.currentGeneration != generation { return .cancelled }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if controller.lastRefreshTimedOut { return .timedOut }
        guard controller.currentGeneration == generation else { return .cancelled }
        if controller.isRefreshing {
            controller.finishTimedOut(generation: generation)
            return .timedOut
        }
        switch controller.state {
        case .loaded(let items, _): return .refreshed(items.count)
        case .empty: return .refreshed(0)
        case .unconfigured: return .unconfigured
        case .authenticationRequired: return .signInRequired
        case .unsupportedPage: return .unsupportedPage
        case .stale(_, _, let reason):
            switch reason {
            case .signInRequired: return .signInRequired
            case .pageWasNotAList: return .unsupportedPage
            case .timedOut: return .timedOut
            case .extractionFailed: return .failed
            }
        case .extractionFailed: return .failed
        case .loadingPage, .extracting: return .cancelled
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
