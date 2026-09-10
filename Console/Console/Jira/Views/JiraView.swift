import SwiftUI
import WebKit

/// Process-scoped WebPage so navigating away from JIRA and back keeps the live session.
@MainActor
final class JiraWebSession {
    static let shared = JiraWebSession()

    let page = WebPage()
    /// Survives Home unmount so cards and last extraction remain when returning.
    let panelController = JiraPanelController()
    /// Browser-style tabs for the full JIRA destination. The pinned first tab
    /// wraps `page`; Home cards and extraction always track that page.
    /// New tabs start at the configured JIRA URL. Memory-only.
    lazy var tabStore = BrowserTabStore(
        pinnedTabs: [(page: page, title: "My Tickets")],
        newTabURLProvider: {
            UserDefaults.standard.string(forKey: "webViewJiraURL")
                .flatMap(JiraView.normalizedURL(from:))
        }
    )
    /// Normalized URL string last loaded into `page`, if any.
    var lastLoadedURLString: String?
    /// True while the retained page intentionally shows a card or deep-link
    /// navigation target instead of the configured list. Memory-only.
    var isShowingNavigatedPage = false

    private init() {}

    /// Whether the retained page already shows what the user intends and must
    /// not be yanked back to the configured list when the destination
    /// remounts. A card/deep-link navigation target survives remounts; an
    /// explicit settings change (`force`) never does.
    nonisolated static func shouldKeepRetainedPage(
        configuredURLString: String,
        lastLoadedURLString: String?,
        isShowingNavigatedPage: Bool,
        force: Bool
    ) -> Bool {
        if force { return false }
        if isShowingNavigatedPage { return true }
        return lastLoadedURLString == configuredURLString
    }
}

extension JiraWebSession: JiraPageServicing {
    var pageURL: URL? { page.url }

    func load(url: URL) {
        lastLoadedURLString = url.absoluteString
        isShowingNavigatedPage = false
        page.load(URLRequest(url: url))
    }

    func reload() {
        page.reload()
    }

    func navigate(to url: URL) {
        lastLoadedURLString = url.absoluteString
        isShowingNavigatedPage = true
        page.load(URLRequest(url: url))
    }

    func readiness() async -> JiraReadiness? {
        do {
            let raw = try await page.callJavaScript(JiraListExtractor.readinessProbeScript)
            guard let json = raw as? String,
                  let data = json.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return nil
            }
            if object["authLike"] as? Bool == true {
                return .authenticationDetected
            }
            return .pending(
                hasRows: object["hasRows"] as? Bool ?? false,
                hasContainer: object["hasTable"] as? Bool ?? false
            )
        } catch {
            return nil
        }
    }

    func extractTickets() async -> JiraListExtraction {
        await JiraListExtractor.extract(from: page)
    }
}

/// Dedicated embedded WebView for the user's configured JIRA URL.
struct JiraView: View {
    @AppStorage("webViewJiraURL") private var webViewJiraURL: String = ""
    @Environment(SessionLaunchCoordinator.self) private var launchCoordinator
    @Environment(SessionWorkspaceStore.self) private var workspaceStore
    /// A WebPage may be presented in only one WebView at a time on macOS 26.
    /// Mounting this WebView in the same transaction that dismantles the Home
    /// quadrant's WebView over the same shared page traps in WebKit. Deferring
    /// the mount by one runloop hop guarantees the old presentation is gone
    /// before this one attaches.
    @State private var isWebViewMounted = false

    /// The page the tab strip currently presents. Home cards and DOM
    /// extraction always use `JiraWebSession.shared.page` (the pinned first
    /// tab) regardless of this value.
    private var page: WebPage {
        JiraWebSession.shared.tabStore.activePage
    }

    var body: some View {
        Group {
            if let url = Self.normalizedURL(from: webViewJiraURL) {
                VStack(spacing: 0) {
                    BrowserTabBar(store: JiraWebSession.shared.tabStore)

                    navigationControls

                    if page.isLoading {
                        ProgressView(value: page.estimatedProgress)
                            .progressViewStyle(.linear)
                    }

                    if isWebViewMounted {
                        WebView(page)
                            .webViewBackForwardNavigationGestures(.enabled)
                            .webViewMagnificationGestures(.enabled)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityIdentifier("JiraWebView")
                    } else {
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .onAppear {
                    mountWebViewAfterSettling()
                    // Long-idle tabs reload in place before anything else so
                    // the destination never presents hour-old content.
                    JiraWebSession.shared.tabStore.reloadStaleTabs()
                    if let pending = JiraDeepLink.shared.consume() {
                        // Home story cards land in their own tab; the pinned
                        // list page (Home panels, extraction) stays untouched.
                        JiraWebSession.shared.tabStore.openTab(url: pending)
                        return
                    }
                    loadIfNeeded(url: url, force: false)
                }
                .onChange(of: webViewJiraURL) { _, newValue in
                    guard let updated = Self.normalizedURL(from: newValue) else { return }
                    loadIfNeeded(url: updated, force: true)
                }
                .onChange(of: JiraWebSession.shared.tabStore.activeTabID) { _, _ in
                    remountWebViewForTabSwitch()
                }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var navigationControls: some View {
        HStack(spacing: 12) {
            Button {
                if let item = page.backForwardList.backList.last {
                    page.load(item)
                }
            } label: {
                Image(systemName: "chevron.backward")
            }
            .disabled(page.backForwardList.backList.isEmpty)
            .help("Back")

            Button {
                if let item = page.backForwardList.forwardList.first {
                    page.load(item)
                }
            } label: {
                Image(systemName: "chevron.forward")
            }
            .disabled(page.backForwardList.forwardList.isEmpty)
            .help("Forward")

            Button {
                if page.isLoading {
                    page.stopLoading()
                } else {
                    page.reload()
                }
            } label: {
                Image(systemName: page.isLoading ? "xmark" : "arrow.clockwise")
            }
            .help(page.isLoading ? "Stop" : "Reload")

            // One-click session launch when the retained page displays an issue.
            if case let .jira(key, title, url) = currentIssueContext, let url {
                Button {
                    Task {
                        await launchCoordinator.beginJiraTicketLaunch(key: key, title: title, url: url)
                    }
                } label: {
                    Label("Start Session", systemImage: "terminal")
                        .labelStyle(.titleAndIcon)
                }
                .controlSize(.small)
                .help("Start a Claude session for this ticket")
                .accessibilityIdentifier("Jira.StartSessionButton")
            }

            BrowserURLField(page: page, accessibilityIdentifier: "Jira.URLField")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityIdentifier("JiraWebViewControls")
    }

    /// Memory-only context parsed from the URL the retained WebView is
    /// currently showing. Nothing here is fetched or persisted.
    private var currentIssueContext: SessionLaunchSource? {
        guard !page.isLoading, let url = page.url,
              let key = JiraSourceContext.parseIssueKey(fromURL: url) else {
            return nil
        }
        return .jira(key: key, title: page.title, url: url)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "j.square")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("Set Web View JIRA URL in Settings")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("JiraEmptyState")
    }

    /// Mounts the WebView on the next runloop hop so the previous presentation
    /// of the shared page (the Home quadrant, or this destination itself) is
    /// fully dismantled first.
    private func mountWebViewAfterSettling() {
        guard !isWebViewMounted else { return }
        DispatchQueue.main.async {
            isWebViewMounted = true
        }
    }

    /// A WebPage may be attached to only one live WebView at a time, so the
    /// WebView is dismantled and remounted one runloop hop apart when the
    /// active tab changes.
    private func remountWebViewForTabSwitch() {
        isWebViewMounted = false
        mountWebViewAfterSettling()
    }

    /// Always targets the pinned main page: re-appearing at the destination
    /// must never yank a free tab back to the configured list.
    private func loadIfNeeded(url: URL, force: Bool) {
        let session = JiraWebSession.shared
        if JiraWebSession.shouldKeepRetainedPage(
            configuredURLString: url.absoluteString,
            lastLoadedURLString: session.lastLoadedURLString,
            isShowingNavigatedPage: session.isShowingNavigatedPage,
            force: force
        ) {
            return
        }
        session.lastLoadedURLString = url.absoluteString
        session.isShowingNavigatedPage = false
        session.page.load(URLRequest(url: url))
    }

    /// Trims whitespace and prepends `https://` when the scheme is missing.
    static func normalizedURL(from raw: String) -> URL? {
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
        else {
            return nil
        }
        return url
    }
}

#Preview {
    JiraView()
        .environment(SessionStore())
        .environment(SessionWorkspaceStore())
        .environment(SessionLaunchCoordinator(store: SessionStore(), workspaceStore: SessionWorkspaceStore()))
}
