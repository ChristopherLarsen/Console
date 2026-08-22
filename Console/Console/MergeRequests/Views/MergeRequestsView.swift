import SwiftUI
import WebKit

/// Dedicated embedded WebView destination for the user's configured GitLab
/// merge-request lists.
///
/// A compact To Review / My MRs selector renders the corresponding shared page
/// from `GitLabWebSessionStore`. Both pages share one authenticated website
/// data store while keeping independent navigation histories.
struct MergeRequestsView: View {
    @AppStorage(AppSettings.webViewGitLabReviewsURLKey) private var webViewGitLabReviewsURL: String = ""
    @AppStorage(AppSettings.webViewGitLabMyMergeRequestsURLKey) private var webViewGitLabMyMergeRequestsURL: String = ""
    @AppStorage(AppSettings.webViewMergeRequestsURLLegacyKey) private var legacyWebViewMergeRequestsURL: String = ""

    @State private var selectedKind: GitLabListKind = .reviewsRequested

    var body: some View {
        Group {
            if let url = configuredURL(for: selectedKind) {
                VStack(spacing: 0) {
                    listSelector
                    GitLabMergeRequestsBrowserView(
                        page: sessionStore.page(for: selectedKind),
                        webViewAccessibilityIdentifier: "MergeRequestsWebView"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .onAppear {
                    loadSelectedList(url: url)
                }
                .onChange(of: selectedKind) { _, newKind in
                    if let updated = configuredURL(for: newKind) {
                        sessionStore.loadIfNeeded(newKind, url: updated, force: false)
                    }
                }
                .onChange(of: webViewGitLabReviewsURL) { _, _ in reloadIfConfigured() }
                .onChange(of: webViewGitLabMyMergeRequestsURL) { _, _ in reloadIfConfigured() }
                .onChange(of: legacyWebViewMergeRequestsURL) { _, _ in reloadIfConfigured() }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sessionStore: GitLabWebSessionStore { GitLabWebSessionStore.shared }

    // MARK: - Selector

    private var listSelector: some View {
        Picker("Merge request list", selection: $selectedKind) {
            Text(GitLabListKind.reviewsRequested.displayTitle).tag(GitLabListKind.reviewsRequested)
            Text(GitLabListKind.authored.displayTitle).tag(GitLabListKind.authored)
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

    /// Effective configured URL per list. The reviews list conservatively falls
    /// back to the legacy generic Merge Requests URL; configured URLs are never
    /// logged.
    private func configuredURL(for kind: GitLabListKind) -> URL? {
        let raw: String
        switch kind {
        case .reviewsRequested:
            raw = GitLabConfiguration.effectiveReviewsURLString()
        case .authored:
            raw = GitLabConfiguration.effectiveAuthoredURLString()
        }
        return GitLabListURLNormalization.url(from: raw)
    }

    private func loadSelectedList(url: URL) {
        sessionStore.loadIfNeeded(selectedKind, url: url, force: false)
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

            switch selectedKind {
            case .reviewsRequested:
                Text("Set Web View GitLab Reviews URL in Settings")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .authored:
                Text("Set Web View GitLab My MRs URL in Settings")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MergeRequestsEmptyState")
    }
}

#Preview {
    MergeRequestsView()
}
