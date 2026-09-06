import SwiftUI
import WebKit

/// Navigation bar around a shared hosted page: back/forward/reload controls,
/// Start Session when the page displays a merge request, plus Show Cards when
/// the panel has extracted content to present.
struct MergeRequestsNavigationBar: View {
    let page: WebPage
    var showCardsAction: (() -> Void)?
    var showCardsAvailable: Bool = true

    @Environment(SessionLaunchCoordinator.self) private var launchCoordinator

    /// Memory-only context parsed from the URL the retained WebView is
    /// currently showing. Nothing here is fetched or persisted.
    private var currentMergeRequestContext: SessionLaunchSource? {
        guard !page.isLoading, let url = page.url else { return nil }
        return MergeRequestSourceContext.launchSource(forURL: url, pageTitle: page.title)
    }

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

            // One-click review launch when the retained page displays an MR.
            if case let .mergeRequest(iid, title, url) = currentMergeRequestContext {
                Button {
                    Task {
                        await launchCoordinator.beginMergeRequestReview(iid: iid, title: title, url: url)
                    }
                } label: {
                    Label("Start Session", systemImage: "terminal")
                        .labelStyle(.titleAndIcon)
                }
                .controlSize(.small)
                .help("Start a Claude review session for this merge request")
                .accessibilityIdentifier("MergeRequests.StartSessionButton")
            }

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

/// Full browser experience for one shared hosted page: the navigation bar
/// above an interactive WebView. Used by the Merge Requests sidebar
/// destination with its To Review / My list selector; each page keeps its own
/// navigation history.
struct MergeRequestsBrowserView: View {
    let page: WebPage
    var showCardsAction: (() -> Void)?
    var showCardsAvailable: Bool = true
    /// Applied to the WebView itself so UI tests can find it reliably.
    var webViewAccessibilityIdentifier: String = ""

    var body: some View {
        VStack(spacing: 0) {
            MergeRequestsNavigationBar(
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
