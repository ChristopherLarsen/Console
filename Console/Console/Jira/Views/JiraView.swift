import SwiftUI
import WebKit

/// Process-scoped WebPage so navigating away from JIRA and back keeps the live session.
@MainActor
final class JiraWebSession {
    static let shared = JiraWebSession()

    let page = WebPage()
    /// Normalized URL string last loaded into `page`, if any.
    var lastLoadedURLString: String?

    private init() {}
}

/// Dedicated embedded WebView for the user's configured JIRA URL.
struct JiraView: View {
    @AppStorage("webViewJiraURL") private var webViewJiraURL: String = ""

    private var page: WebPage { JiraWebSession.shared.page }

    var body: some View {
        Group {
            if let url = Self.normalizedURL(from: webViewJiraURL) {
                WebView(page)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("JiraWebView")
                    .onAppear {
                        loadIfNeeded(url: url, force: false)
                    }
                    .onChange(of: webViewJiraURL) { _, newValue in
                        guard let updated = Self.normalizedURL(from: newValue) else { return }
                        loadIfNeeded(url: updated, force: true)
                    }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private func loadIfNeeded(url: URL, force: Bool) {
        let normalized = url.absoluteString
        if !force, JiraWebSession.shared.lastLoadedURLString == normalized {
            return
        }
        JiraWebSession.shared.lastLoadedURLString = normalized
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
    JiraView()
}
