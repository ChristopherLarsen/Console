import SwiftUI
import WebKit

/// One observable controller per merge-request list kind. Owns the panel
/// state, card/browser presentation, loading/readiness/extraction orchestration,
/// manual reload with stale-result protection, and card navigation.
///
/// No polling timer: extraction runs after an explicit load or refresh, or
/// after an observed navigation while sign-in recovery is active. Authentication
/// is not treated as an ordinary extraction failure.
@MainActor
@Observable
final class CodeHostListPanelController {

    enum Presentation: Equatable {
        case cards
        case browser
    }

    /// Decodes one extractor JSON payload. Production uses the shared
    /// `MergeRequestListExtractor`; tests substitute deterministic decoders.
    typealias PayloadDecoder = (String) throws -> MergeRequestListExtractionResult

    /// Yields navigation events on the retained page. Production forwards
    /// `WebPage.navigations`; tests substitute a controllable stream.
    typealias NavigationEventSource = @MainActor (WebPage) -> AsyncStream<WebPage.NavigationEvent>

    // MARK: - Configuration

    private let kind: CodeHostListKind
    private let page: WebPage
    private let configuredURLStringProvider: () -> String?
    private let payloadDecoder: PayloadDecoder
    private let now: () -> Date

    /// Bounded local readiness loop parameters. DOM checks only.
    private let readinessAttempts: Int
    private let readinessIntervalNanoseconds: UInt64

    /// Navigation and extraction seams. Production uses WebKit directly;
    /// tests substitute deterministic implementations.
    private let pageLoader: @MainActor (WebPage, URLRequest) async -> Bool
    private let extractionExecutor: @MainActor (WebPage) async throws -> String?
    private let navigationEvents: NavigationEventSource

    // MARK: - Observable state

    private(set) var state: MergeRequestListPanelState = .unconfigured
    private(set) var presentation: Presentation = .cards
    private(set) var isRefreshing = false

    /// True when in-flight work was cancelled because the panel disappeared.
    private(set) var isSuspended = false

    /// True when the next appearance should start or resume extraction
    /// rather than preserving the current cards.
    private(set) var needsExtraction = false

    /// True while sign-in recovery should observe later navigations.
    /// Survives a cancelled watch so appearance can resume it.
    private(set) var wantsAuthenticationObservation = false

    /// True while a navigation-watch task is actually running.
    private(set) var isObservingSignInNavigations = false

    /// Prior cards kept only in memory while authentication is underway.
    /// Never presented, never persisted, never logged.
    private(set) var hiddenItems: [MergeRequestSummary] = []

    private var hiddenRefreshedAt: Date?
    private var generation = 0
    private var extractionTask: Task<Void, Never>?
    private var navigationWatchTask: Task<Void, Never>?
    private var lastConfiguredURLString: String?

    init(
        kind: CodeHostListKind,
        page: WebPage,
        configuredURLStringProvider: @escaping () -> String?,
        now: @escaping () -> Date = { Date() },
        readinessAttempts: Int = 12,
        readinessIntervalNanoseconds: UInt64 = 250_000_000,
        pageLoader: (@MainActor (WebPage, URLRequest) async -> Bool)? = nil,
        extractionExecutor: (@MainActor (WebPage) async throws -> String?)? = nil,
        payloadDecoder: PayloadDecoder? = nil,
        navigationEvents: NavigationEventSource? = nil
    ) {
        self.kind = kind
        self.page = page
        self.configuredURLStringProvider = configuredURLStringProvider
        self.payloadDecoder = payloadDecoder ?? MergeRequestListExtractor.decode
        self.now = now
        self.readinessAttempts = max(1, readinessAttempts)
        self.readinessIntervalNanoseconds = readinessIntervalNanoseconds
        self.pageLoader = pageLoader ?? CodeHostListPanelController.defaultLoadPage
        self.extractionExecutor = extractionExecutor ?? CodeHostListPanelController.defaultExecuteExtraction
        self.navigationEvents = navigationEvents ?? CodeHostListPanelController.defaultNavigationEvents
    }

    // MARK: - Lifecycle

    /// Loads, resumes, or re-binds the configured list when the view appears.
    func startIfNeeded() {
        syncWithConfiguration(resumeIncomplete: true)
    }

    /// Called when the configured URL may have changed; restarts work only if
    /// the effective URL actually changed.
    func configurationChanged() {
        syncWithConfiguration(resumeIncomplete: false)
    }

    /// Starts or resumes extraction if the current URL still needs work;
    /// otherwise performs a manual reload. The first load is not doubled.
    ///
    /// While sign-in recovery owns the retained page, no reload is forced:
    /// loading the list URL would abort an in-progress SSO round trip. The
    /// active navigation watch re-extracts when sign-in completes.
    func startOrRefresh() {
        startIfNeeded()
        if wantsAuthenticationObservation {
            return
        }
        if !isRefreshing {
            refresh()
        }
    }

    /// Manual reload of the ordinary configured list page. Prior cards are
    /// retained until a complete successful extraction replaces them; a
    /// failed refresh marks them stale instead of showing a false zero.
    func refresh(forceReload: Bool = true) {
        beginExtraction(invalidatingSource: false, forceReload: forceReload)
    }

    /// Cancels pending extraction when the view is torn down. The retained
    /// page itself stays alive in the session store. Incomplete first-loads
    /// and in-flight sign-in observation are marked suspended so the next
    /// appearance can resume them.
    func cancelPendingWork() {
        let wasWatching = navigationWatchTask != nil || wantsAuthenticationObservation
        let wasInFlight = extractionTask != nil || isRefreshing || wasWatching
        extractionTask?.cancel()
        extractionTask = nil
        stopAuthenticationWatch(keepingIntent: true)
        isRefreshing = false
        if wasInFlight {
            generation += 1
            if Self.isIncomplete(state) || wantsAuthenticationObservation {
                isSuspended = true
                needsExtraction = true
            }
        }
    }

    // MARK: - Presentation

    func showBrowser() {
        presentation = .browser
    }

    /// Browser-bar entry point. Restores the card surface immediately when a
    /// definite answer exists; while work is in flight it just reveals the
    /// progress; after a failure state it returns to cards and retries the
    /// configured list so the button always makes progress instead of dying
    /// silently with no way back out of browser mode.
    ///
    /// Authentication is different: the login WebView stays revealed. Show
    /// Cards is not a way to cover the sign-in page.
    func showCardsIfAvailable() {
        switch state {
        case .loaded, .empty, .stale, .loadingPage, .extracting:
            presentation = .cards
        case .unconfigured, .authenticationRequired:
            break
        case .unsupportedPage:
            if wantsAuthenticationObservation {
                presentation = .browser
                return
            }
            presentation = .cards
            refresh()
        case .extractionFailed:
            presentation = .cards
            refresh()
        }
    }

    /// True when Show Cards may cover the retained page. Sign-in keeps the
    /// WebView interactive, so it is not offered here.
    var canShowCards: Bool {
        switch state {
        case .loaded, .empty, .stale, .loadingPage, .extracting:
            return true
        case .unsupportedPage, .extractionFailed:
            return !wantsAuthenticationObservation
        case .authenticationRequired, .unconfigured:
            return false
        }
    }

    /// Reveals the same retained page and navigates it to the captured MR URL.
    /// Ordinary navigation cancels any in-flight list extraction so a late
    /// payload scraped from the detail page can never replace the panel.
    func open(_ item: MergeRequestSummary) {
        let wasInFlight = extractionTask != nil || isRefreshing
        cancelInFlightDOMExtraction()
        if wasInFlight, Self.isIncomplete(state) {
            needsExtraction = true
        }
        presentation = .browser
        page.load(URLRequest(url: item.mergeRequestURL))
    }

    var itemCount: Int {
        state.retainedItems.count
    }

    /// Current extraction generation, internal so tests can drive
    /// `apply(_:generation:)` deterministically.
    var currentGeneration: Int { generation }

    // MARK: - Sign-in navigation

    /// Forwards a navigation event from the retained page. Tests call this
    /// directly with a synthetic completed-sign-in sequence; production
    /// forwards `WebPage.navigations` while sign-in recovery is active.
    func handleObservedNavigation(_ event: WebPage.NavigationEvent) {
        guard wantsAuthenticationObservation else { return }
        switch event {
        case .startedProvisionalNavigation, .committed:
            cancelInFlightDOMExtraction()
        case .finished:
            beginExtraction(invalidatingSource: false, forceReload: false)
        case .receivedServerRedirect:
            break
        @unknown default:
            break
        }
    }

    // MARK: - Extraction pipeline

    private func runExtraction(url: URL, requestedGeneration: Int, forceReload: Bool) async {
        defer { settleRefreshingIfCurrent(requestedGeneration) }

        if forceReload {
            let didLoad = await pageLoader(page, URLRequest(url: url))
            guard isCurrent(requestedGeneration) else { return }

            guard didLoad else {
                applyOrdinaryFailure(.extractionFailed, reason: .extractionFailed)
                return
            }
        }

        switch state {
        case .loaded, .stale, .authenticationRequired:
            break
        case .unsupportedPage where wantsAuthenticationObservation:
            break
        default:
            if forceReload {
                state = .extracting
            }
        }

        var outcome: MergeRequestListExtractionResult?
        for attempt in 0..<readinessAttempts where !Task.isCancelled {
            guard isCurrent(requestedGeneration) else { return }
            if let result = await extractOnce() {
                // A decisive answer ends the readiness loop; `unsupported`
                // keeps waiting briefly because the host may still be rendering.
                guard isCurrent(requestedGeneration) else { return }
                outcome = result
                if !isIndeterminate(result) { break }
            }
            if attempt < readinessAttempts - 1 {
                try? await Task.sleep(nanoseconds: readinessIntervalNanoseconds)
                guard isCurrent(requestedGeneration) else { return }
            }
        }

        guard isCurrent(requestedGeneration) else { return }

        guard let outcome else {
            // No attempt ever produced a readable payload: our extraction
            // machinery failed; this is not evidence of an unsupported page.
            applyOrdinaryFailure(.extractionFailed, reason: .extractionFailed)
            return
        }
        apply(outcome, generation: requestedGeneration)
    }

    /// Returns true when the main-frame navigation reached `.finished`.
    private static func defaultLoadPage(_ page: WebPage, request: URLRequest) async -> Bool {
        let events = page.load(request)
        do {
            for try await event in events {
                switch event {
                case .finished:
                    return true
                case .startedProvisionalNavigation, .committed, .receivedServerRedirect:
                    continue
                @unknown default:
                    continue
                }
            }
        } catch {
            return false
        }
        return false
    }

    /// Production extraction: run the GitLab DOM inspector via
    /// callJavaScript and return the JSON payload string.
    private static func defaultExecuteExtraction(_ page: WebPage) async throws -> String? {
        try await page.callJavaScript(GitLabListExtractorJavaScript.source) as? String
    }

    /// Forwards every later navigation on the retained page. Never reloads,
    /// never reads cookies, and never issues network probes.
    private static func defaultNavigationEvents(_ page: WebPage) -> AsyncStream<WebPage.NavigationEvent> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                do {
                    for try await event in page.navigations {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func extractOnce() async -> MergeRequestListExtractionResult? {
        guard let json = try? await extractionExecutor(page),
              let decoded = try? payloadDecoder(json)
        else { return nil }
        return decoded
    }

    private func isIndeterminate(_ result: MergeRequestListExtractionResult) -> Bool {
        switch result {
        case .unsupportedPage: return true
        case .authenticationRequired: return false
        case .empty: return false
        case .items: return false
        }
    }

    /// Atomically applies one extraction outcome. Internal (not private) so
    /// tests can drive generation-rejection deterministically.
    func apply(_ outcome: MergeRequestListExtractionResult, generation appliedGeneration: Int) {
        guard appliedGeneration == self.generation else { return }
        apply(outcome)
        isRefreshing = false
        needsExtraction = false
        isSuspended = false
    }

    private func apply(_ outcome: MergeRequestListExtractionResult) {
        let timestamp = now()

        switch outcome {
        case .items(let items):
            clearHiddenItems()
            stopAuthenticationWatch(keepingIntent: false)
            state = items.isEmpty ? .empty(refreshedAt: timestamp) : .loaded(items: items, refreshedAt: timestamp)
            presentation = .cards

        case .empty:
            clearHiddenItems()
            stopAuthenticationWatch(keepingIntent: false)
            state = .empty(refreshedAt: timestamp)
            presentation = .cards

        case .authenticationRequired:
            enterAuthenticationRequired()

        case .unsupportedPage:
            applyUnsupportedPage()
        }
    }

    private func enterAuthenticationRequired() {
        stashPresentedItems()
        state = .authenticationRequired
        presentation = .browser
        wantsAuthenticationObservation = true
        startAuthenticationNavigationWatch()
    }

    private func applyUnsupportedPage() {
        if wantsAuthenticationObservation {
            // Same-origin (or SSO) non-list page stays usable in the
            // retained WebView. Keep watching for a later list.
            state = .unsupportedPage
            presentation = .browser
            startAuthenticationNavigationWatch()
            return
        }
        retainOr(.unsupportedPage, reason: .pageWasNotAList)
    }

    /// Ordinary extraction/navigation failure: keep labelled stale cards when
    /// they exist, including cards that were only hidden for sign-in.
    private func applyOrdinaryFailure(
        _ failureState: MergeRequestListPanelState,
        reason: MergeRequestRefreshFailureReason
    ) {
        if !hiddenItems.isEmpty, let hiddenRefreshedAt {
            state = .stale(items: hiddenItems, refreshedAt: hiddenRefreshedAt, reason: reason)
            presentation = .cards
            clearHiddenItems()
            stopAuthenticationWatch(keepingIntent: false)
            return
        }
        if wantsAuthenticationObservation {
            // No prior cards to restore: leave the current page usable.
            presentation = .browser
            return
        }
        retainOr(failureState, reason: reason)
    }

    /// On failure states, keep prior cards as stale rather than presenting a
    /// false zero. Without prior cards, surface the specific failure state.
    private func retainOr(_ failureState: MergeRequestListPanelState, reason: MergeRequestRefreshFailureReason) {
        switch state {
        case .loaded(let items, let refreshedAt):
            state = .stale(items: items, refreshedAt: refreshedAt, reason: reason)
        case .stale(let items, let refreshedAt, _):
            state = .stale(items: items, refreshedAt: refreshedAt, reason: reason)
        default:
            state = failureState
        }
    }

    private func stashPresentedItems() {
        switch state {
        case .loaded(let items, let refreshedAt), .stale(let items, let refreshedAt, _):
            hiddenItems = items
            hiddenRefreshedAt = refreshedAt
        default:
            break
        }
    }

    private func clearHiddenItems() {
        hiddenItems = []
        hiddenRefreshedAt = nil
    }

    private func startAuthenticationNavigationWatch() {
        wantsAuthenticationObservation = true
        if navigationWatchTask != nil {
            isObservingSignInNavigations = true
            return
        }
        isObservingSignInNavigations = true
        let page = self.page
        let source = self.navigationEvents
        navigationWatchTask = Task { [weak self] in
            let stream = source(page)
            for await event in stream {
                guard let self else { break }
                self.handleObservedNavigation(event)
            }
            self?.navigationWatchTask = nil
            self?.isObservingSignInNavigations = false
        }
    }

    private func stopAuthenticationWatch(keepingIntent: Bool) {
        navigationWatchTask?.cancel()
        navigationWatchTask = nil
        isObservingSignInNavigations = false
        if !keepingIntent {
            wantsAuthenticationObservation = false
        }
    }

    /// Drops an in-flight DOM readiness loop so a newer navigation can own
    /// the next extraction. Does not reload the page.
    private func cancelInFlightDOMExtraction() {
        guard extractionTask != nil || isRefreshing else { return }
        extractionTask?.cancel()
        extractionTask = nil
        generation += 1
        isRefreshing = false
    }

    private func syncWithConfiguration(resumeIncomplete: Bool) {
        guard let url = effectiveConfiguredURL() else {
            applyMissingConfiguration()
            return
        }

        if lastConfiguredURLString != url.absoluteString {
            beginExtraction(invalidatingSource: true)
            return
        }

        if resumeIncomplete, !isRefreshing, needsExtraction || Self.isIncomplete(state) {
            if wantsAuthenticationObservation {
                startAuthenticationNavigationWatch()
                beginExtraction(invalidatingSource: false, forceReload: false)
                return
            }
            beginExtraction(invalidatingSource: false)
        } else if resumeIncomplete, wantsAuthenticationObservation, navigationWatchTask == nil {
            startAuthenticationNavigationWatch()
        }
    }

    private func applyMissingConfiguration() {
        extractionTask?.cancel()
        extractionTask = nil
        stopAuthenticationWatch(keepingIntent: false)
        clearHiddenItems()
        generation += 1
        lastConfiguredURLString = nil
        needsExtraction = false
        isSuspended = false
        isRefreshing = false
        presentation = .cards
        state = .unconfigured
    }

    private func beginExtraction(invalidatingSource: Bool, forceReload: Bool = true) {
        extractionTask?.cancel()
        extractionTask = nil
        generation += 1
        let currentGeneration = generation
        needsExtraction = false
        isSuspended = false

        guard let url = effectiveConfiguredURL() else {
            lastConfiguredURLString = nil
            isRefreshing = false
            stopAuthenticationWatch(keepingIntent: false)
            clearHiddenItems()
            state = .unconfigured
            return
        }

        lastConfiguredURLString = url.absoluteString
        isRefreshing = true
        if invalidatingSource {
            stopAuthenticationWatch(keepingIntent: false)
            clearHiddenItems()
            state = .loadingPage
        } else if forceReload {
            switch state {
            case .loaded, .stale:
                break // keep prior cards visible during a same-source refresh
            case .authenticationRequired:
                break
            default:
                state = .loadingPage
            }
        }

        extractionTask = Task { [weak self] in
            await self?.runExtraction(
                url: url,
                requestedGeneration: currentGeneration,
                forceReload: forceReload
            )
        }
    }

    private func effectiveConfiguredURL() -> URL? {
        configuredURLStringProvider().flatMap(ListURLNormalization.url(from:))
    }

    private func isCurrent(_ requestedGeneration: Int) -> Bool {
        !Task.isCancelled && generation == requestedGeneration
    }

    private func settleRefreshingIfCurrent(_ requestedGeneration: Int) {
        guard generation == requestedGeneration else { return }
        isRefreshing = false
        needsExtraction = false
        isSuspended = false
        extractionTask = nil
    }

    private static func isIncomplete(_ state: MergeRequestListPanelState) -> Bool {
        switch state {
        case .loadingPage, .extracting:
            return true
        default:
            return false
        }
    }
}

/// URL handling shared by the panel controllers and sidebar views. Values are
/// user-configured exact list URLs; Console never builds query parameters and
/// never logs them.
enum ListURLNormalization {
    static func normalized(_ raw: String?) -> String? {
        url(from: raw).map { $0.absoluteString }
    }

    /// Trims whitespace, prepends `https://` when the scheme is missing, and
    /// accepts only http(s) URLs with a host.
    static func url(from raw: String?) -> URL? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let withScheme: String
        if let scheme = URL(string: trimmed)?.scheme, !scheme.isEmpty {
            withScheme = trimmed
        } else {
            withScheme = "https://\(trimmed)"
        }

        guard let url = URL(string: withScheme),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return url
    }
}
