import SwiftUI
import WebKit

/// Navigation bar around a shared GitLab page: back/forward/reload controls
/// plus Show Cards when the panel has extracted content to present.
struct GitLabBrowserNavigationBar: View {
    let page: WebPage
    var showCardsAction: (() -> Void)?
    var showCardsAvailable: Bool = true

    var body: some View {
        HStack(spacing: 10) {
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

            if let showCardsAction {
                Button("Show Cards") {
                    showCardsAction()
                }
                .disabled(!showCardsAvailable)
                .help("Return to native cards")
            }

            Spacer(minLength: 0)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

/// Full browser experience for one shared GitLab page: the navigation bar
/// above an interactive WebView. Used by the Merge Requests sidebar
/// destination with its To Review / My MRs selector; each page keeps its own
/// navigation history.
struct GitLabMergeRequestsBrowserView: View {
    let page: WebPage
    var showCardsAction: (() -> Void)?
    var showCardsAvailable: Bool = true
    /// Applied to the WebView itself so UI tests can find it reliably.
    var webViewAccessibilityIdentifier: String = ""

    var body: some View {
        VStack(spacing: 0) {
            GitLabBrowserNavigationBar(
                page: page,
                showCardsAction: showCardsAction,
                showCardsAvailable: showCardsAvailable
            )

            if page.isLoading {
                ProgressView(value: page.estimatedProgress)
                    .progressViewStyle(.linear)
            }

            WebView(page)
                .webViewBackForwardNavigationGestures(.enabled)
                .webViewMagnificationGestures(.enabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier(webViewAccessibilityIdentifier)
        }
    }
}
