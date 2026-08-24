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
    func loadIfNeeded(_ kind: CodeHostListKind, url: URL, force: Bool = false) {
        let normalized = url.absoluteString
        if !force, lastLoadedURLStrings[kind] == normalized { return }
        lastLoadedURLStrings[kind] = normalized
        page(for: kind).load(URLRequest(url: url))
    }

    /// Builds one page bound to `dataStore`. Shared by both list kinds; every
    /// hosted page must go through here so no isolated store can appear.
    static func makePage(dataStore: WKWebsiteDataStore) -> WebPage {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = dataStore
        return WebPage(configuration: configuration)
    }
}
