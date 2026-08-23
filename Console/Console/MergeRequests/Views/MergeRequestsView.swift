import SwiftUI
import WebKit

/// Dedicated embedded WebView destination for the user's configured
/// merge-request lists on the active code host.
///
/// A compact To Review / My list selector renders the corresponding shared
/// page from that host's session store. Both pages share one authenticated
/// website data store while keeping independent navigation histories.
/// Switching hosts in Settings swaps to the other host's retained pages
/// without disturbing either session.
struct MergeRequestsView: View {
    @AppStorage(AppSettings.codeHostProviderKey) private var codeHostProviderRaw: String = CodeHostProvider.gitlab.rawValue
    @AppStorage(AppSettings.webViewGitLabReviewsURLKey) private var webViewGitLabReviewsURL: String = ""
    @AppStorage(AppSettings.webViewGitLabMyMergeRequestsURLKey) private var webViewGitLabMyMRsURL: String = ""
    @AppStorage(AppSettings.webViewMergeRequestsURLLegacyKey) private var legacyWebViewMergeRequestsURL: String = ""
    @AppStorage(AppSettings.webViewGitHubReviewsURLKey) private var webViewGitHubReviewsURL: String = ""
    @AppStorage(AppSettings.webViewGitHubMyPullRequestsURLKey) private var webViewGitHubMyPRsURL: String = ""

    /// Starts on the list a pending Next-card deep link targets, so the link
    /// lands on the visible page.
    @State private var selectedKind: CodeHostListKind =
        MergeRequestDeepLink.shared.consumeKindHint() ?? .authored

    private var activeProvider: CodeHostProvider {
        CodeHostProvider(rawValue: codeHostProviderRaw) ?? .gitlab
    }

    var body: some View {
        Group {
            if let url = configuredURL(for: selectedKind) {
                VStack(spacing: 0) {
                    listSelector
                    MergeRequestsBrowserView(
                        page: sessionStore.page(for: selectedKind),
                        webViewAccessibilityIdentifier: "MergeRequestsWebView"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .onAppear {
                    loadSelectedList(url: url)
                    consumePendingDeepLink()
                }
                .onChange(of: selectedKind) { _, newKind in
                    if let updated = configuredURL(for: newKind) {
                        sessionStore.loadIfNeeded(newKind, url: updated, force: false)
                    }
                    consumePendingDeepLink()
                }
                .onChange(of: codeHostProviderRaw) { _, _ in reloadIfConfigured() }
                .onChange(of: webViewGitLabReviewsURL) { _, _ in reloadIfConfigured() }
                .onChange(of: webViewGitLabMyMRsURL) { _, _ in reloadIfConfigured() }
                .onChange(of: legacyWebViewMergeRequestsURL) { _, _ in reloadIfConfigured() }
                .onChange(of: webViewGitHubReviewsURL) { _, _ in reloadIfConfigured() }
                .onChange(of: webViewGitHubMyPRsURL) { _, _ in reloadIfConfigured() }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sessionStore: CodeHostWebSessionStore {
        CodeHostWebSessionStore.shared(for: activeProvider)
    }

    // MARK: - Selector

    private var listSelector: some View {
        Picker("Merge request list", selection: $selectedKind) {
            Text(CodeHostListKind.reviewsRequested.displayTitle).tag(CodeHostListKind.reviewsRequested)
            Text(CodeHostListKind.authored.displayTitle(in: activeProvider)).tag(CodeHostListKind.authored)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityIdentifier("MergeRequestsListSelector")
    }

    // MARK: - Configuration

    /// Effective configured URL per list for the active host. The GitLab
    /// reviews list conservatively falls back to the legacy generic Merge
    /// Requests URL; configured URLs are never logged.
    private func configuredURL(for kind: CodeHostListKind) -> URL? {
        ListURLNormalization.url(
            from: CodeHostConfiguration.effectiveURLString(for: kind, provider: activeProvider)
        )
    }

    private func loadSelectedList(url: URL) {
        sessionStore.loadIfNeeded(selectedKind, url: url, force: false)
    }

    /// Loads the merge request a Next-card tap queued for this list, after
    /// the ordinary list bookkeeping so it wins.
    private func consumePendingDeepLink() {
        guard let url = MergeRequestDeepLink.shared.consume(matching: selectedKind) else { return }
        sessionStore.page(for: selectedKind).load(URLRequest(url: url))
    }

    private func reloadIfConfigured() {
        guard let url = configuredURL(for: selectedKind) else { return }
        sessionStore.loadIfNeeded(selectedKind, url: url, force: true)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: activeProvider.sidebarIcon)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("Set Web View \(activeProvider.displayName) \(selectedKind.settingsNoun(in: activeProvider)) URL in Settings")
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
    /// Authored-list label per host (`My MRs` vs `My PRs`); reviews title is
    /// host-neutral.
    func displayTitle(in provider: CodeHostProvider) -> String {
        switch self {
        case .reviewsRequested: return displayTitle
        case .authored:
            switch provider {
            case .gitlab: return "My MRs"
            case .github: return "My PRs"
            }
        }
    }

    /// Noun used in unconfigured-state copy ("Reviews"/"My MRs").
    func settingsNoun(in provider: CodeHostProvider) -> String {
        switch self {
        case .reviewsRequested: return "Reviews"
        case .authored: return displayTitle(in: provider)
        }
    }
}

extension CodeHostProvider {
    /// Sidebar icon for the merge-requests destination.
    var sidebarIcon: String {
        switch self {
        case .gitlab: return "arrow.triangle.merge"
        case .github: return "arrow.triangle.pull"
        }
    }
}

#Preview {
    MergeRequestsView()
}
