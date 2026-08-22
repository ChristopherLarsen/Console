import SwiftUI
import WebKit

/// Process-scoped WebPage so navigating away from Merge Requests and back keeps the live session.
@MainActor
final class MergeRequestsWebSession {
    static let shared = MergeRequestsWebSession()

    let page = WebPage()
    /// Normalized URL string last loaded into `page`, if any.
    var lastLoadedURLString: String?

    private init() {}
}

/// Dedicated embedded WebView for the user's configured Merge Requests URL.
struct MergeRequestsView: View {
    @AppStorage("webViewMergeRequestsURL") private var webViewMergeRequestsURL: String = ""
    @Environment(SessionLaunchCoordinator.self) private var launchCoordinator
    @State private var page = MergeRequestsWebSession.shared.page

    var body: some View {
        Group {
            if let url = Self.normalizedURL(from: webViewMergeRequestsURL) {
                VStack(spacing: 0) {
                    navigationControls

                    if page.isLoading {
                        ProgressView(value: page.estimatedProgress)
                            .progressViewStyle(.linear)
                    }

                    WebView(page)
                        .webViewBackForwardNavigationGestures(.enabled)
                        .webViewMagnificationGestures(.enabled)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("MergeRequestsWebView")
                }
                .onAppear {
                    loadIfNeeded(url: url, force: false)
                }
                .onChange(of: webViewMergeRequestsURL) { _, newValue in
                    guard let updated = Self.normalizedURL(from: newValue) else { return }
                    loadIfNeeded(url: updated, force: true)
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

            // One-click review launch when the retained page displays an MR.
            if case let .gitLabMergeRequest(iid, title, url) = currentMergeRequestContext {
                Button {
                    launchCoordinator.beginMergeRequestReview(iid: iid, title: title, url: url)
                } label: {
                    Label("Start Session", systemImage: "terminal")
                        .labelStyle(.titleAndIcon)
                }
                .controlSize(.small)
                .help("Start a Claude review session for this merge request")
                .accessibilityIdentifier("MergeRequests.StartSessionButton")
            }

            Text(page.url?.absoluteString ?? page.title)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(page.url?.absoluteString ?? "")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityIdentifier("MergeRequestsWebViewControls")
    }

    /// Memory-only context parsed from the URL the retained WebView is
    /// currently showing. Nothing here is fetched or persisted.
    private var currentMergeRequestContext: SessionLaunchSource? {
        guard !page.isLoading, let url = page.url,
              let info = GitLabSourceContext.parseMergeRequest(fromURL: url) else {
            return nil
        }
        return .gitLabMergeRequest(iid: info.iid, title: page.title, url: url)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("Set Web View Merge Requests URL in Settings")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("MergeRequestsEmptyState")
    }

    private func loadIfNeeded(url: URL, force: Bool) {
        let normalized = url.absoluteString
        if !force, MergeRequestsWebSession.shared.lastLoadedURLString == normalized {
            return
        }
        MergeRequestsWebSession.shared.lastLoadedURLString = normalized
        page.load(URLRequest(url: url))
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
    MergeRequestsView()
        .environment(SessionStore())
        .environment(SessionWorkspaceStore())
        .environment(SessionLaunchCoordinator(store: SessionStore(), workspaceStore: SessionWorkspaceStore()))
}
