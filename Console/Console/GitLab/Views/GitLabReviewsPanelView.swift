import SwiftUI
import WebKit

/// Home Panel 3 (bottom-left): native "MRs to Review" cards over the live,
/// authenticated GitLab review list.
///
/// A `ZStack` keeps the shared reviews `WebView` permanently attached while an
/// opaque native card surface covers it. In card mode the covered WebView has
/// hit testing disabled and is hidden from accessibility, but the page stays
/// alive so Show GitLab / Show Cards never loses authentication or history.
struct GitLabReviewsPanelView: View {
    @AppStorage(AppSettings.webViewGitLabReviewsURLKey) private var webViewGitLabReviewsURL: String = ""
    @AppStorage(AppSettings.webViewMergeRequestsURLLegacyKey) private var legacyWebViewMergeRequestsURL: String = ""
    @AppStorage("sidebarSelection") private var sidebarSelection: SidebarSelection = .home

    @State private var controller = GitLabListPanelController(
        kind: .reviewsRequested,
        page: GitLabWebSessionStore.shared.reviewsPage,
        configuredURLStringProvider: { GitLabConfiguration.effectiveReviewsURLString() }
    )

    private let kind = GitLabListKind.reviewsRequested

    private var effectiveConfiguredURLString: String {
        GitLabConfiguration.effectiveReviewsURLString()
    }

    var body: some View {
        ZStack(alignment: .top) {
            webViewLayer

            if controller.presentation == .browser {
                GitLabBrowserNavigationBar(
                    page: GitLabWebSessionStore.shared.reviewsPage,
                    showCardsAction: { controller.showCardsIfAvailable() },
                    showCardsAvailable: controller.state.hasPresentableCards
                )
                .transition(.opacity)
            }

            if controller.presentation == .cards {
                cardSurface
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .animation(.easeOut(duration: 0.15), value: controller.presentation)
        .onAppear {
            controller.startIfNeeded()
        }
        .onDisappear {
            controller.cancelPendingWork()
        }
        .onChange(of: effectiveConfiguredURLString) {
            controller.configurationChanged()
        }
    }

    // MARK: - WebView layer (always attached)

    /// The shared reviews page. Covered in card mode: hit testing off and
    /// hidden from accessibility, but attached so state is never lost.
    private var webViewLayer: some View {
        let isCovered = controller.presentation == .cards
        return WebView(GitLabWebSessionStore.shared.reviewsPage)
            .webViewBackForwardNavigationGestures(.enabled)
            .webViewMagnificationGestures(.enabled)
            .allowsHitTesting(!isCovered)
            .accessibilityHidden(isCovered)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Card surface

    private var cardSurface: some View {
        VStack(spacing: 0) {
            chromeHeader
            Divider()

            switch controller.state {
            case .unconfigured:
                unconfiguredState
            case .loadingPage, .extracting:
                loadingState
            case .authenticationRequired:
                authenticationState
            case .loaded(let items, _):
                cardsList(items)
            case .empty:
                emptyState
            case .stale(let items, _, let reason):
                cardsList(items, staleNotice: reason.reasonText)
            case .unsupportedPage:
                unsupportedState
            case .extractionFailed:
                extractionFailedState
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(1))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chromeHeader: some View {
        HStack(spacing: 8) {
            Text("Reviews Requested · \(controller.itemCount)")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if controller.isRefreshing {
                ProgressView()
                    .controlSize(.mini)
                    .help("Refreshing")
            }

            Spacer(minLength: 4)

            Button {
                controller.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(!hasConfiguredURL)
            .help("Refresh from GitLab")
            .accessibilityIdentifier("GitLabPanelRefreshButton")

            if controller.presentation == .cards {
                Button("Show GitLab") {
                    controller.showBrowser()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Show the live GitLab page")
                .accessibilityIdentifier("GitLabPanelShowGitLabButton")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func cardsList(_ items: [GitLabMergeRequestSummary], staleNotice: String? = nil) -> some View {
        VStack(spacing: 0) {
            if let staleNotice {
                Label(staleNotice, systemImage: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .accessibilityIdentifier("GitLabPanelStaleNotice")
                Divider()
            }

            ScrollView(.vertical) {
                LazyVStack(spacing: 6) {
                    ForEach(items) { item in
                        GitLabMergeRequestCardView(item: item) {
                            controller.open(item)
                        }
                    }
                }
                .padding(8)
            }
        }
    }

    // MARK: - Panel states

    private var unconfiguredState: some View {
        panelMessage(
            systemImage: "link.badge.plus",
            title: "Set your GitLab review list URL in Settings.",
            detail: kind.listExpectationText,
            actionTitle: "Open Settings",
            action: { sidebarSelection = .settings },
            accessibilityIdentifier: "GitLabPanelUnconfiguredState"
        )
    }

    private var loadingState: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Loading GitLab…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("GitLabPanelLoadingState")
    }

    private var authenticationState: some View {
        panelMessage(
            systemImage: "lock.shield",
            title: "Sign in to GitLab to load your review list.",
            detail: "Use Show GitLab to sign in; Console never sees your credentials.",
            actionTitle: "Show GitLab",
            action: { controller.showBrowser() },
            accessibilityIdentifier: "GitLabPanelAuthenticationState"
        )
    }

    private var emptyState: some View {
        panelMessage(
            systemImage: "checkmark.seal",
            title: "No merge requests waiting for your review.",
            detail: nil,
            actionTitle: nil,
            action: nil,
            accessibilityIdentifier: "GitLabPanelEmptyState"
        )
    }

    private var unsupportedState: some View {
        panelMessage(
            systemImage: "questionmark.square.dashed",
            title: "This page is not a merge-request list.",
            detail: kind.listExpectationText,
            actionTitle: "Show GitLab",
            action: { controller.showBrowser() },
            accessibilityIdentifier: "GitLabPanelUnsupportedState"
        )
    }

    private var extractionFailedState: some View {
        panelMessage(
            systemImage: "exclamationmark.triangle",
            title: "Console could not read the rendered list.",
            detail: "Try Refresh, or use Show GitLab for the raw page.",
            actionTitle: "Refresh",
            action: { controller.refresh() },
            accessibilityIdentifier: "GitLabPanelExtractionFailedState"
        )
    }

    private func panelMessage(
        systemImage: String,
        title: String,
        detail: String?,
        actionTitle: String?,
        action: (() -> Void)?,
        accessibilityIdentifier identifier: String
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 24))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.callout)
                .multilineTextAlignment(.center)

            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    // MARK: - Helpers

    private var hasConfiguredURL: Bool {
        !effectiveConfiguredURLString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }
}

extension GitLabListPanelState {
    /// Whether Show Cards may restore the opaque card surface right now.
    var hasPresentableCards: Bool {
        switch self {
        case .loaded, .empty, .stale:
            return true
        default:
            return false
        }
    }
}

#Preview("Panel 3") {
    GitLabReviewsPanelView()
        .frame(width: 420, height: 300)
}
