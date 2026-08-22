import SwiftUI
import WebKit

/// Process-scoped owner of the two retained GitLab pages.
///
/// Both pages are constructed with the SAME explicit persistent
/// `WKWebsiteDataStore`, so signing into GitLab in one page makes the browser
/// session available to the other. Each page keeps its own back-forward list.
///
/// This type is the only GitLab `WebPage` owner in the app. It replaces the
/// former single-page `MergeRequestsWebSession`.
@MainActor
final class GitLabWebSessionStore {
    static let shared = GitLabWebSessionStore()

    /// The one explicit persistent store both pages are configured with.
    /// Never inspected for cookies, tokens, or other site data by Console.
    let websiteDataStore: WKWebsiteDataStore

    let reviewsPage: WebPage
    let authoredPage: WebPage

    /// Normalized URL string last requested per page, so re-appearing views do
    /// not reload a page that already shows the configured list.
    private var lastLoadedURLStrings: [GitLabListKind: String] = [:]

    init(
        dataStore: WKWebsiteDataStore = WKWebsiteDataStore.default(),
        pageProvider: @escaping (WKWebsiteDataStore) -> WebPage = GitLabWebSessionStore.makePage
    ) {
        self.websiteDataStore = dataStore
        self.reviewsPage = pageProvider(dataStore)
        self.authoredPage = pageProvider(dataStore)
    }

    func page(for kind: GitLabListKind) -> WebPage {
        switch kind {
        case .reviewsRequested: return reviewsPage
        case .authored: return authoredPage
        }
    }

    /// Loads `url` unless this page already had that exact URL requested.
    func loadIfNeeded(_ kind: GitLabListKind, url: URL, force: Bool = false) {
        let normalized = url.absoluteString
        if !force, lastLoadedURLStrings[kind] == normalized { return }
        lastLoadedURLStrings[kind] = normalized
        page(for: kind).load(URLRequest(url: url))
    }

    /// Builds one page bound to `dataStore`. Shared by both list kinds; every
    /// GitLab page must go through here so no isolated store can appear.
    static func makePage(dataStore: WKWebsiteDataStore) -> WebPage {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = dataStore
        return WebPage(configuration: configuration)
    }
}
