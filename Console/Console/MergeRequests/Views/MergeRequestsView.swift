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

    /// Starts on the list a pending Next-card deep link targets, so the link
    /// lands on the visible page.
    @State private var selectedKind: CodeHostListKind =
        MergeRequestDeepLink.shared.consumeKindHint() ?? .authored

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
                .onChange(of: webViewGitLabReviewsURL) { _, _ in reloadIfConfigured() }
                .onChange(of: webViewGitLabMyMRsURL) { _, _ in reloadIfConfigured() }
                .onChange(of: legacyWebViewMergeRequestsURL) { _, _ in reloadIfConfigured() }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sessionStore: CodeHostWebSessionStore {
        CodeHostWebSessionStore.shared
    }

    // MARK: - Selector

    private var listSelector: some View {
        Picker("Merge request list", selection: $selectedKind) {
            Text(CodeHostListKind.reviewsRequested.displayTitle).tag(CodeHostListKind.reviewsRequested)
            Text(CodeHostListKind.authored.displayTitle).tag(CodeHostListKind.authored)
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

    /// Effective configured URL per list. The reviews list conservatively
    /// falls back to the legacy generic Merge Requests URL; configured URLs
    /// are never logged.
    private func configuredURL(for kind: CodeHostListKind) -> URL? {
        ListURLNormalization.url(
            from: CodeHostConfiguration.effectiveURLString(for: kind)
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
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("Set Web View GitLab \(selectedKind.settingsNoun) URL in Settings")
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
