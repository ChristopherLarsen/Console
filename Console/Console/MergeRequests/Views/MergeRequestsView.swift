import SwiftUI
import WebKit

/// Dedicated embedded WebView destination for the user's configured
/// merge-request lists on GitLab.
///
/// A compact To Review / My list selector renders the corresponding shared
/// page from the session store. Both pages share one authenticated website
/// data store while keeping independent navigation histories.
struct MergeRequestsView: View {
    @AppStorage(AppSettings.webViewGitLabReviewsURLKey) private var webViewGitLabReviewsURL: String = ""
    @AppStorage(AppSettings.webViewGitLabMyMergeRequestsURLKey) private var webViewGitLabMyMRsURL: String = ""
    @AppStorage(AppSettings.webViewMergeRequestsURLLegacyKey) private var legacyWebViewMergeRequestsURL: String = ""

    /// A WebPage may be attached to only one live WebView at a time on
    /// macOS 26; the WebView is dismantled and remounted one runloop hop
    /// apart when the active tab changes.
    @State private var isWebViewMounted = false

    private var sessionStore: CodeHostWebSessionStore {
        CodeHostWebSessionStore.shared
    }

    private var tabStore: BrowserTabStore {
        sessionStore.tabStore
    }

    /// The retained list kind backing the active tab, or nil for a free tab.
    private var activeKind: CodeHostListKind? {
        guard let index = tabStore.tabs.firstIndex(where: { $0.id == tabStore.activeTabID }) else {
            return nil
        }
        return Self.kind(forPinnedIndex: index)
    }

    private var hasAnyConfiguredURL: Bool {
        CodeHostListKind.allCases.contains { configuredURL(for: $0) != nil }
    }

    var body: some View {
        Group {
            if hasAnyConfiguredURL {
                VStack(spacing: 0) {
                    BrowserTabBar(store: tabStore)

                    if isWebViewMounted {
                        MergeRequestsBrowserView(
                            page: tabStore.activePage,
                            webViewAccessibilityIdentifier: "MergeRequestsWebView"
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .onAppear {
                    mountWebViewAfterSettling()
                    selectPinnedTabIfHinted()
                    loadActiveList()
                    consumePendingDeepLink()
                }
                .onChange(of: tabStore.activeTabID) { _, _ in
                    remountWebViewForTabSwitch()
                    loadActiveList()
                    consumePendingDeepLink()
                }
                .onChange(of: webViewGitLabReviewsURL) { _, _ in reloadList(.reviewsRequested) }
                .onChange(of: webViewGitLabMyMRsURL) { _, _ in reloadList(.authored) }
                .onChange(of: legacyWebViewMergeRequestsURL) { _, _ in reloadList(.reviewsRequested) }
            } else if let kind = activeKind {
                emptyState(for: kind)
            } else {
                emptyState(for: .reviewsRequested)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Tabs

    /// Pinned tab order: 0 = reviews, 1 = authored.
    private static func kind(forPinnedIndex index: Int) -> CodeHostListKind? {
        switch index {
        case 0: return .reviewsRequested
        case 1: return .authored
        default: return nil
        }
    }

    private func pinnedIndex(for kind: CodeHostListKind) -> Int {
        kind == .reviewsRequested ? 0 : 1
    }

    /// Selects the pinned tab a pending kind-only deep link targets so a
    /// Next-card handoff lands on the visible list.
    private func selectPinnedTabIfHinted() {
        guard let kind = MergeRequestDeepLink.shared.consumeKindHint() else { return }
        tabStore.select(tabStore.tabs[pinnedIndex(for: kind)].id)
    }

    /// Loads the merge request a Next-card tap queued for the active list,
    /// after the ordinary list bookkeeping so it wins.
    private func consumePendingDeepLink() {
        guard let kind = activeKind,
              let url = MergeRequestDeepLink.shared.consume(matching: kind) else { return }
        sessionStore.page(for: kind).load(URLRequest(url: url))
    }

    // MARK: - Mounting

    private func mountWebViewAfterSettling() {
        guard !isWebViewMounted else { return }
        DispatchQueue.main.async {
            isWebViewMounted = true
        }
    }

    private func remountWebViewForTabSwitch() {
        isWebViewMounted = false
        mountWebViewAfterSettling()
    }

    // MARK: - Configuration

    /// Effective configured URL per list. The reviews list conservatively
    /// falls back to the legacy generic Merge Requests URL; configured URLs
    /// are never logged.
    private func configuredURL(for kind: CodeHostListKind) -> URL? {
        ListURLNormalization.url(
            from: CodeHostConfiguration.effectiveURLString(for: kind)
        )
    }

    /// Loads the active pinned list's configured URL unless that page already
    /// had it requested. Free tabs are never redirected here.
    private func loadActiveList() {
        guard let kind = activeKind, let url = configuredURL(for: kind) else { return }
        sessionStore.loadIfNeeded(kind, url: url, force: false)
    }

    private func reloadList(_ kind: CodeHostListKind) {
        guard let url = configuredURL(for: kind) else { return }
        sessionStore.loadIfNeeded(kind, url: url, force: true)
    }

    private func emptyState(for kind: CodeHostListKind) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("Set Web View GitLab \(kind.settingsNoun) URL in Settings")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MergeRequestsEmptyState")
    }
}

extension CodeHostListKind {
    /// Noun used in unconfigured-state copy ("Reviews"/"My MRs").
    var settingsNoun: String {
        switch self {
        case .reviewsRequested: return "Reviews"
        case .authored: return displayTitle
        }
    }
}

#Preview {
    MergeRequestsView()
}
