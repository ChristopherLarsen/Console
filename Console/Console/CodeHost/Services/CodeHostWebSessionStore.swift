import SwiftUI
import WebKit

/// Process-scoped owner of the two retained pages for one code host.
///
/// Both pages are constructed with the SAME explicit persistent
/// `WKWebsiteDataStore`, so signing into the host in one page makes the
/// browser session available to the other. Each page keeps its own
/// back-forward list.
///
/// Each provider owns its own store instance (`shared(for:)`); both
/// instances share WebKit's default persistent website data store, which
/// safely holds each host's cookies side by side. Switching hosts never
/// touches the inactive host's pages or session.
@MainActor
final class CodeHostWebSessionStore {
    private static var instances: [CodeHostProvider: CodeHostWebSessionStore] = [:]

    /// The process-wide store for `provider`, creating it on first use.
    static func shared(for provider: CodeHostProvider) -> CodeHostWebSessionStore {
        if let existing = instances[provider] { return existing }
        let store = CodeHostWebSessionStore()
        instances[provider] = store
        return store
    }

    /// Convenience for the currently configured host.
    static var active: CodeHostWebSessionStore {
        shared(for: AppSettings().codeHostProvider)
    }

    /// The one explicit persistent store both pages are configured with.
    /// Never inspected for cookies, tokens, or other site data by Console.
    let websiteDataStore: WKWebsiteDataStore

    let reviewsPage: WebPage
    let authoredPage: WebPage

    /// Normalized URL string last requested per page, so re-appearing views do
    /// not reload a page that already shows the configured list.
    private var lastLoadedURLStrings: [CodeHostListKind: String] = [:]

    init(
        dataStore: WKWebsiteDataStore = WKWebsiteDataStore.default(),
        pageProvider: @escaping (WKWebsiteDataStore) -> WebPage = CodeHostWebSessionStore.makePage
    ) {
        self.websiteDataStore = dataStore
        self.reviewsPage = pageProvider(dataStore)
        self.authoredPage = pageProvider(dataStore)
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
