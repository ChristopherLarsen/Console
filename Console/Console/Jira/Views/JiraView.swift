import SwiftUI
import WebKit

/// Process-scoped WebPage so navigating away from JIRA and back keeps the live session.
@MainActor
final class JiraWebSession {
    static let shared = JiraWebSession()

    let page = WebPage()
    /// Survives Home unmount so cards and last extraction remain when returning.
    let panelController = JiraPanelController()
    /// Normalized URL string last loaded into `page`, if any.
    var lastLoadedURLString: String?

    private init() {}
}

extension JiraWebSession: JiraPageServicing {
    var pageURL: URL? { page.url }

    func load(url: URL) {
        lastLoadedURLString = url.absoluteString
        page.load(URLRequest(url: url))
    }

    func reload() {
        page.reload()
    }

    func navigate(to url: URL) {
        lastLoadedURLString = nil
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
    @State private var page = JiraWebSession.shared.page

    var body: some View {
        Group {
            if let url = Self.normalizedURL(from: webViewJiraURL) {
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
                        .accessibilityIdentifier("JiraWebView")
                }
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
            if case let .jira(key, title, url) = currentIssueContext {
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
        .environment(SessionStore())
        .environment(SessionWorkspaceStore())
        .environment(SessionLaunchCoordinator(store: SessionStore(), workspaceStore: SessionWorkspaceStore()))
}
