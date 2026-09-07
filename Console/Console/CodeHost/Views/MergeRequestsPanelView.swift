import SwiftUI
import WebKit

/// Shared Home merge-request panel (reviews and authored quadrants): native
/// cards over the live, authenticated GitLab list page.
///
/// A `ZStack` keeps the shared list `WebView` permanently attached while an
/// opaque native card surface covers it. In card mode the covered WebView has
/// hit testing disabled and is hidden from accessibility, but the page stays
/// alive so Show GitLab / Show Cards never loses authentication or history.
struct MergeRequestsPanelView: View {
    let kind: CodeHostListKind

    @AppStorage(AppSettings.webViewGitLabReviewsURLKey) private var webViewGitLabReviewsURL: String = ""
    @AppStorage(AppSettings.webViewGitLabMyMergeRequestsURLKey) private var webViewGitLabMyMRsURL: String = ""
    @AppStorage(AppSettings.webViewMergeRequestsURLLegacyKey) private var legacyWebViewMergeRequestsURL: String = ""
    @AppStorage("sidebarSelection") private var sidebarSelection: SidebarSelection = .home

    private var controller: CodeHostListPanelController {
        MergeRequestListSession.shared.controller(for: kind)
    }

    private var effectiveConfiguredURLString: String {
        CodeHostConfiguration.effectiveURLString(for: kind)
    }

    private var sessionStore: CodeHostWebSessionStore {
        CodeHostWebSessionStore.shared
    }

    private var idPrefix: String {
        "GitLabPanel"
    }

    var body: some View {
        VStack(spacing: 0) {
            if controller.presentation == .browser {
                MergeRequestsNavigationBar(
                    page: sessionStore.page(for: kind),
                    showCardsAction: { controller.showCardsIfAvailable() },
                    showCardsAvailable: controller.canShowCards
                )
                .transition(.opacity)

                if case .authenticationRequired = controller.state {
                    signInNotice
                }
            }

            ZStack(alignment: .top) {
                webViewLayer

                if controller.presentation == .cards {
                    cardSurface
                        .transition(.opacity)
                }
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
        .onChange(of: allConfiguredURLs) {
            controller.configurationChanged()
        }
    }

    /// Every hosted URL preference; observing them all lets a change to any
    /// one re-evaluate this panel's own effective configuration safely.
    private var allConfiguredURLs: String {
        [
            webViewGitLabReviewsURL,
            webViewGitLabMyMRsURL,
            legacyWebViewMergeRequestsURL,
        ]
        .joined(separator: "\n")
    }

    // MARK: - WebView layer (always attached)

    /// The shared list page. Covered in card mode: hit testing off and hidden
    /// from accessibility, but attached so state is never lost. Authentication
    /// uses browser presentation so the page is interactive and VoiceOver can
    /// reach it.
    private var webViewLayer: some View {
        let isCovered = controller.presentation == .cards
        return WebView(sessionStore.page(for: kind))
            .webViewBackForwardNavigationGestures(.enabled)
            .webViewMagnificationGestures(.enabled)
            .allowsHitTesting(!isCovered)
            .accessibilityHidden(isCovered)
            .accessibilityIdentifier("\(idPrefix)WebView")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Generic sign-in copy shown outside the WebView. Never includes URLs,
    /// hostnames, or credentials.
    private var signInNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.system(size: 12, weight: .medium))
            VStack(alignment: .leading, spacing: 2) {
                Text("Sign in to GitLab")
                    .font(.system(size: 11, weight: .medium))
                Text("Complete sign-in in the page below. Console never sees your credentials. Cards return when the list is available.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sign in to GitLab. Complete sign-in in the embedded browser. Console never sees your credentials. Cards return when the list is available.")
        .accessibilityIdentifier("\(idPrefix)SignInNotice")
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
            case .stale(let items, let refreshedAt, let reason):
                cardsList(items, staleNotice: reason.reasonText, refreshedAt: refreshedAt)
            case .unsupportedPage:
                unsupportedState
            case .extractionFailed:
                extractionFailedState
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(1))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The panel's one 28pt header: title, service and count as a quiet run,
    /// then icon-only actions.
    private var chromeHeader: some View {
        HomePanelHeader(
            title: kind.displayTitle,
            detail: {
                HomePanelDetail("GitLab", "\(controller.itemCount)")
            },
            accessory: {
                if controller.isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                        .help("Refreshing")
                }

                Button {
                    controller.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(!hasConfiguredURL)
                .help("Refresh from GitLab")
                .accessibilityIdentifier("\(idPrefix)RefreshButton")

                if controller.presentation == .cards {
                    Button {
                        controller.showBrowser()
                    } label: {
                        Image(systemName: "macwindow.on.rectangle")
                    }
                    .help("Show the live GitLab page")
                    .accessibilityIdentifier("\(idPrefix)ShowGitLabButton")
                }
            }
        )
    }

    @ViewBuilder
    private func cardsList(
        _ items: [MergeRequestSummary],
        staleNotice: String? = nil,
        refreshedAt: Date? = nil
    ) -> some View {
        VStack(spacing: 0) {
            if let staleNotice {
                staleStrip(notice: staleNotice, refreshedAt: refreshedAt)
                Divider()
            }

            ScrollView(.vertical) {
                LazyVStack(spacing: HomeCardMetrics.listGap) {
                    ForEach(items) { item in
                        MergeRequestCardView(item: item, kind: kind) {
                            controller.open(item)
                        }
                    }
                }
                .padding(8)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    /// Amber strip naming the age of what you are looking at, plus a way out.
    /// Cards below stay at full strength — they are old, not wrong.
    private func staleStrip(notice: String, refreshedAt: Date?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 9, weight: .medium))
            Text(staleText(refreshedAt: refreshedAt))
                .font(.system(size: 10))
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("Retry") {
                controller.refresh()
            }
            .disabled(controller.isRefreshing)
            .accessibilityIdentifier("\(idPrefix)StaleRetryButton")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .foregroundStyle(Color.orange)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(Color.orange.opacity(0.12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Showing previous results (\(notice))")
        .accessibilityIdentifier("\(idPrefix)StaleNotice")
    }

    private func staleText(refreshedAt: Date?) -> String {
        guard let refreshedAt else { return "Showing previous results" }
        return "Showing results from \(refreshedAt.formatted(date: .omitted, time: .shortened))"
    }

    // MARK: - Panel states

    private var unconfiguredState: some View {
        panelMessage(
            systemImage: "link.badge.plus",
            title: unconfiguredTitle,
            detail: kind.listExpectationText,
            actionTitle: "Open Settings",
            action: { sidebarSelection = .settings },
            accessibilityIdentifier: "\(idPrefix)UnconfiguredState"
        )
    }

    private var unconfiguredTitle: String {
        switch kind {
        case .reviewsRequested: return "Set your GitLab review list URL in Settings."
        case .authored: return "Set your GitLab authored MR list URL in Settings."
        }
    }

    private var loadingState: some View {
        VStack(spacing: HomeCardMetrics.listGap) {
            ForEach(0..<4, id: \.self) { index in
                HomeSkeletonCard()
                    .opacity(index == 3 ? 0.5 : 1)
            }
            Spacer()
        }
        .padding(8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading GitLab")
        .accessibilityIdentifier("\(idPrefix)LoadingState")
    }

    private var authenticationState: some View {
        panelMessage(
            systemImage: "lock.shield",
            title: authenticationTitle,
            detail: "Complete sign-in in the embedded browser. Console never sees your credentials.",
            actionTitle: nil,
            action: nil,
            accessibilityIdentifier: "\(idPrefix)AuthenticationState"
        )
    }

    private var authenticationTitle: String {
        switch kind {
        case .reviewsRequested: return "Sign in to GitLab to load your review list."
        case .authored: return "Sign in to GitLab to load your authored MR list."
        }
    }

    private var emptyState: some View {
        panelMessage(
            systemImage: "checkmark.seal",
            title: emptyStateTitle,
            detail: nil,
            actionTitle: nil,
            action: nil,
            accessibilityIdentifier: "\(idPrefix)EmptyState"
        )
    }

    private var emptyStateTitle: String {
        switch kind {
        case .reviewsRequested: return "No merge requests waiting for your review."
        case .authored: return "No open merge requests authored by you."
        }
    }

    private var unsupportedState: some View {
        panelMessage(
            systemImage: "questionmark.square.dashed",
            title: "This page is not a merge-request list.",
            detail: kind.listExpectationText,
            actionTitle: "Show GitLab",
            action: { controller.showBrowser() },
            accessibilityIdentifier: "\(idPrefix)UnsupportedState"
        )
    }

    private var extractionFailedState: some View {
        panelMessage(
            systemImage: "exclamationmark.triangle",
            title: "Console could not read the rendered list.",
            detail: "Try Refresh, or use Show GitLab for the raw page.",
            actionTitle: "Refresh",
            action: { controller.refresh() },
            accessibilityIdentifier: "\(idPrefix)ExtractionFailedState"
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
