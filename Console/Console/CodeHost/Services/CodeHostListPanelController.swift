import SwiftUI
import WebKit

/// One observable controller per merge-request list kind. Owns the panel
/// state, card/browser presentation, loading/readiness/extraction orchestration,
/// manual reload with stale-result protection, and card navigation.
///
/// No polling timer: extraction runs once after an explicit load or refresh.
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

    // MARK: - Observable state

    private(set) var state: MergeRequestListPanelState = .unconfigured
    private(set) var presentation: Presentation = .cards
    private(set) var isRefreshing = false

    private var generation = 0
    private var extractionTask: Task<Void, Never>?
    private var lastConfiguredURLString: String?
    private var hasStarted = false

    init(
        kind: CodeHostListKind,
        page: WebPage,
        configuredURLStringProvider: @escaping () -> String?,
        now: @escaping () -> Date = { Date() },
        readinessAttempts: Int = 12,
        readinessIntervalNanoseconds: UInt64 = 250_000_000,
        pageLoader: (@MainActor (WebPage, URLRequest) async -> Bool)? = nil,
        extractionExecutor: (@MainActor (WebPage) async throws -> String?)? = nil,
        payloadDecoder: PayloadDecoder? = nil
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
    }

    // MARK: - Lifecycle

    /// Loads the configured list and extracts it once when the view appears.
    func startIfNeeded() {
        guard !hasStarted else {
            reevaluateConfiguration()
            return
        }
        hasStarted = true
        refresh()
    }

    /// Called when the configured URL may have changed; restarts work only if
    /// the effective URL actually changed.
    func configurationChanged() {
        guard hasStarted else {
            reevaluateConfiguration()
            return
        }
        let urlString = configuredURLStringProvider().flatMap(ListURLNormalization.normalized)
        if urlString != lastConfiguredURLString {
            refresh(forceReload: true)
        }
    }

    /// Manual reload of the ordinary configured list page. Prior cards are
    /// retained until a complete successful extraction replaces them; a
    /// failed refresh marks them stale instead of showing a false zero.
    func refresh(forceReload: Bool = true) {
        extractionTask?.cancel()
        generation += 1
        let currentGeneration = generation

        guard let raw = configuredURLStringProvider(),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            lastConfiguredURLString = nil
            state = .unconfigured
            return
        }

        guard let url = ListURLNormalization.url(from: raw) else {
            lastConfiguredURLString = nil
            state = .unconfigured
            return
        }

        lastConfiguredURLString = url.absoluteString
        isRefreshing = true
        switch state {
        case .loaded, .stale:
            break // keep prior cards visible during the refresh
        default:
            state = .loadingPage
        }

        extractionTask = Task { [weak self] in
            await self?.runExtraction(url: url, requestedGeneration: currentGeneration)
        }
    }

    /// Cancels pending extraction when the view is torn down. The retained
    /// page itself stays alive in the session store.
    func cancelPendingWork() {
        extractionTask?.cancel()
        extractionTask = nil
        isRefreshing = false
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
    func showCardsIfAvailable() {
        switch state {
        case .loaded, .empty, .stale, .loadingPage, .extracting:
            presentation = .cards
        case .unconfigured:
            break
        case .authenticationRequired, .unsupportedPage, .extractionFailed:
            presentation = .cards
            refresh()
        }
    }

    /// Reveals the same retained page and navigates it to the captured MR URL.
    func open(_ item: MergeRequestSummary) {
        presentation = .browser
        page.load(URLRequest(url: item.mergeRequestURL))
    }

    var itemCount: Int {
        state.retainedItems.count
    }

    /// Current extraction generation, internal so tests can drive
    /// `apply(_:generation:)` deterministically.
    var currentGeneration: Int { generation }

    // MARK: - Extraction pipeline

    private func runExtraction(url: URL, requestedGeneration: Int) async {
        let didLoad = await pageLoader(page, URLRequest(url: url))

        guard !Task.isCancelled, generation == requestedGeneration else { return }

        guard didLoad else {
            retainOr(.extractionFailed, reason: .extractionFailed)
            isRefreshing = false
            return
        }

        var outcome: MergeRequestListExtractionResult?
        for attempt in 0..<readinessAttempts where !Task.isCancelled {
            if let result = await extractOnce() {
                // A decisive answer ends the readiness loop; `unsupported`
                // keeps waiting briefly because the host may still be rendering.
                outcome = result
                if !isIndeterminate(result) { break }
            }
            if attempt < readinessAttempts - 1 {
                try? await Task.sleep(nanoseconds: readinessIntervalNanoseconds)
            }
        }

        guard !Task.isCancelled, generation == requestedGeneration else { return }

        guard let outcome else {
            // No attempt ever produced a readable payload: our extraction
            // machinery failed; this is not evidence of an unsupported page.
            retainOr(.extractionFailed, reason: .extractionFailed)
            isRefreshing = false
            return
        }
        apply(outcome)
        isRefreshing = false
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

    /// Production extraction: run the active code host's DOM inspector via
    /// callJavaScript and return the JSON payload string.
    private static func defaultExecuteExtraction(_ page: WebPage) async throws -> String? {
        try await page.callJavaScript(AppSettings().codeHostProvider.extractorJavaScriptSource) as? String
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
    }

    private func apply(_ outcome: MergeRequestListExtractionResult) {
        let timestamp = now()

        switch outcome {
        case .items(let items):
            state = items.isEmpty ? .empty(refreshedAt: timestamp) : .loaded(items: items, refreshedAt: timestamp)

        case .empty:
            state = .empty(refreshedAt: timestamp)

        case .authenticationRequired:
            retainOr(.authenticationRequired, reason: .signInRequired)

        case .unsupportedPage:
            retainOr(.unsupportedPage, reason: .pageWasNotAList)
        }
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

    private func reevaluateConfiguration() {
        let hasURL = configuredURLStringProvider()
            .map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            ?? false
        if !hasURL {
            state = .unconfigured
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
