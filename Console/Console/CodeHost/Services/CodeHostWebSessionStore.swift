import SwiftUI
import WebKit

/// Process-scoped owner of the two retained list pages.
///
/// Both pages are constructed with the SAME explicit persistent
/// `WKWebsiteDataStore`, so signing into GitLab in one page makes the
/// browser session available to the other. Each page keeps its own
/// back-forward list.
@MainActor
final class CodeHostWebSessionStore {
    /// The process-wide store, creating it on first use.
    static let shared = CodeHostWebSessionStore()

    /// The one explicit persistent store both pages are configured with.
    /// Never inspected for cookies, tokens, or other site data by Console.
    let websiteDataStore: WKWebsiteDataStore

    let reviewsPage: WebPage
    let authoredPage: WebPage

    /// Browser-style tabs for the GitLab sidebar destination. The two pinned
    /// tabs wrap the retained list pages (index 0 = reviews, 1 = authored);
    /// dynamic tabs start at the configured reviews URL. Memory-only.
    lazy var tabStore = BrowserTabStore(
        pinnedTabs: [
            (page: reviewsPage, title: CodeHostListKind.reviewsRequested.displayTitle),
            (page: authoredPage, title: CodeHostListKind.authored.displayTitle)
        ],
        newTabURLProvider: {
            ListURLNormalization.url(
                from: CodeHostConfiguration.effectiveURLString(for: .reviewsRequested)
            )
        }
    )

    /// Normalized URL string last requested per page, so re-appearing views do
    /// not reload a page that already shows the configured list.
    private var lastLoadedURLStrings: [CodeHostListKind: String] = [:]

    /// Builds the two pages bound to one data store. Always main-actor
    /// isolated, matching `WebPage`'s own isolation.
    typealias PageProvider = @MainActor (WKWebsiteDataStore) -> WebPage

    init(
        dataStore: WKWebsiteDataStore? = nil,
        pageProvider: PageProvider? = nil
    ) {
        let resolvedDataStore = dataStore ?? WKWebsiteDataStore.default()
        let resolvedPageProvider = pageProvider ?? Self.makePage
        self.websiteDataStore = resolvedDataStore
        self.reviewsPage = resolvedPageProvider(resolvedDataStore)
        self.authoredPage = resolvedPageProvider(resolvedDataStore)
    }

    func page(for kind: CodeHostListKind) -> WebPage {
        switch kind {
        case .reviewsRequested: return reviewsPage
        case .authored: return authoredPage
        }
    }

    /// Loads `url` unless this page already had that exact URL requested.
    ///
    /// The record is written before the load runs; a load that never reaches
    /// `.finished` clears it again so the same URL can be retried on the next
    /// appearance instead of being silently skipped forever.
    func loadIfNeeded(_ kind: CodeHostListKind, url: URL, force: Bool = false) {
        let normalized = url.absoluteString
        if !force, lastLoadedURLStrings[kind] == normalized { return }
        lastLoadedURLStrings[kind] = normalized
        let page = page(for: kind)
        let events = page.load(URLRequest(url: url))
        Task { [weak self] in
            var finished = false
            do {
                for try await event in events {
                    if case .finished = event {
                        finished = true
                        break
                    }
                }
            } catch {
                finished = false
            }
            guard let self, !finished else { return }
            // Only forget the URL if this load is still the one recorded; a
            // later explicit load supersedes it.
            if self.lastLoadedURLStrings[kind] == normalized {
                self.lastLoadedURLStrings[kind] = nil
            }
        }
    }

    /// Recorded last requested URL for a page (inspection/testing seam).
    func recordedURLString(for kind: CodeHostListKind) -> String? {
        lastLoadedURLStrings[kind]
    }

    /// Builds one page bound to `dataStore`. Shared by both list kinds; every
    /// hosted page must go through here so no isolated store can appear.
    static func makePage(dataStore: WKWebsiteDataStore) -> WebPage {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = dataStore
        return WebPage(configuration: configuration)
    }
}
