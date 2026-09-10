import SwiftUI

/// The Home work board: Next, In Progress, and Review. Data comes from the
/// process-scoped Jira panel controller and the reviews-requested MR list.
/// Home mounts NO WebView of its own: the retained `WebPage`s stay hosted by
/// the JIRA and GitLab destinations ("always active" = process-scoped
/// controllers keeping page, session, and last extraction alive), and Home
/// reads the controllers' state plus headless extraction results. Sign-in is
/// never revealed here — the columns show a "Sign in to JIRA" / "Sign in to
/// GitLab" button that opens the owning destination.
struct HomeView: View {
    @AppStorage("webViewJiraURL") private var webViewJiraURL: String = ""
    @Environment(SessionStore.self) private var sessionStore: SessionStore?
    @Environment(SessionLaunchCoordinator.self) private var launchCoordinator
    @Environment(MRReviewScanScheduler.self) private var reviewScanScheduler: MRReviewScanScheduler?

    @State private var sources: HomeSourcesCoordinator
    @State private var model: HomeBoardModel

    init() {
        let jiraController = JiraWebSession.shared.panelController
        let reviewsController = MergeRequestListSession.shared.controller(for: .reviewsRequested)
        _sources = State(initialValue: HomeSourcesCoordinator(
            jiraController: jiraController,
            reviewsController: reviewsController,
            jiraURLProvider: { UserDefaults.standard.string(forKey: "webViewJiraURL") }
        ))
        _model = State(initialValue: HomeBoardModel(
            jiraController: jiraController,
            reviewsController: reviewsController
        ))
    }

    var body: some View {
        board
            .padding(10)
            .background(Color(nsColor: .windowBackgroundColor))
            .onAppear {
                installActionSeams()
                sources.activate()
            }
            .onChange(of: webViewJiraURL) {
                sources.jiraURLChanged()
            }
            .accessibilityIdentifier("HomeDashboard")
    }

    // MARK: - Board

    private var board: some View {
        let snapshot = model.snapshot()
        let board = HomeBoardBuilder.build(snapshot)
        let sessions = sessionStore?.sessions ?? []

        return HStack(alignment: .top, spacing: 12) {
            nextColumn(board)
            inProgressColumn(board, sessions: sessions)
            reviewColumn(board)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottom) {
            if let notice = model.notice {
                Text(notice)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
            }
        }
    }

    // MARK: Next

    /// Next holds one slot: the story slot follows Jira health. The column
    /// itself always renders content; the slot owns its state presentation.
    private func nextColumn(_ board: HomeBoard) -> some View {
        HomeBoardColumn(
            title: "Next Story",
            detail: nil,
            health: .ready,
            content: {
                nextStorySlot(board)
            },
            accessory: {
                HStack(spacing: 6) {
                    HomeRefreshAgeLabel(
                        lastRefresh: model.snapshot().jiraStatus.lastSuccessfulExtraction
                    )
                    .accessibilityIdentifier("HomeNextRefreshAge")

                    Button {
                        sources.refreshJira()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 18, weight: .regular))
                            .frame(minWidth: 28, minHeight: 28)
                            .contentShape(Rectangle())
                    }
                    .help("Refresh Jira")
                    .accessibilityIdentifier("HomeNextRefreshButton")
                }
            }
        )
        .accessibilityIdentifier("HomeNextColumn")
    }

    @ViewBuilder
    private func nextStorySlot(_ board: HomeBoard) -> some View {
        switch board.jiraHealth {
        case .ready:
            if let story = board.nextStory {
                HomeBoardTicketCard(
                    ticket: story,
                    stateLine: story.status,
                    actionLabel: "Open story"
                ) {
                    model.openStory(story)
                }
                .accessibilityIdentifier("HomeNextStoryCard")
            } else {
                HomeBoardPlaceholderCard(
                    title: "No story",
                    detail: "Open JIRA to pick something new.",
                    accessibilityIdentifier: "HomeNextNoStoryPlaceholder"
                )
            }
        case .updating, .stale:
            if let story = board.nextStory {
                HomeBoardTicketCard(
                    ticket: story,
                    stateLine: story.status,
                    actionLabel: "Open story"
                ) {
                    model.openStory(story)
                }
                .accessibilityIdentifier("HomeNextStoryCard")
            }
        case .loading:
            HomeSkeletonCard()
        case .unconfigured, .unavailable:
            recoveryCard(jiraRecovery(for: board.jiraHealth))
        case .signedOut:
            // Sign-in is surfaced only in the Next column.
            recoveryCard(.signInJira)
        }
    }

    // MARK: In Progress

    /// Jira WIP limit: at most six in-progress stories render on the board.
    private static let maxInProgressStories = 6

    /// Review limit: at most six merge requests render on the board.
    private static let maxReviewRequests = 6

    private func inProgressColumn(_ board: HomeBoard, sessions: [ConsoleSession]) -> some View {
        HomeBoardColumn(
            title: "In Progress",
            detail: inProgressDetail(board),
            health: board.jiraHealth,
            recovery: jiraRecovery(for: board.jiraHealth),
            onRecovery: { recover(jiraRecovery(for: board.jiraHealth)) },
            content: {
                if board.inProgressTickets.isEmpty {
                    // A genuine empty claim only on current data; retained
                    // data keeps quiet until a fresh extraction decides.
                    if board.jiraHealth == .ready {
                        HomeBoardPlaceholderCard(
                            title: "No stories in progress",
                            accessibilityIdentifier: "HomeInProgressEmptyPlaceholder"
                        )
                    }
                } else {
                    ForEach(
                        Array(board.inProgressTickets.prefix(Self.maxInProgressStories).enumerated()),
                        id: \.element.key
                    ) { index, ticket in
                        inProgressCard(ticket, sessions: sessions, index: index)
                    }

                    if board.inProgressTickets.count > Self.maxInProgressStories {
                        Text("Additional stories are in progress")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .accessibilityIdentifier("HomeInProgressOverflowFooter")
                    }
                }
            },
            accessory: {
                HStack(spacing: 6) {
                    HomeRefreshAgeLabel(
                        lastRefresh: model.snapshot().jiraStatus.lastSuccessfulExtraction
                    )
                    .accessibilityIdentifier("HomeInProgressRefreshAge")

                    Button {
                        sources.refreshJira()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 18, weight: .regular))
                            .frame(minWidth: 28, minHeight: 28)
                            .contentShape(Rectangle())
                    }
                    .help("Refresh Jira")
                    .accessibilityIdentifier("HomeInProgressRefreshButton")
                }
            }
        )
        .accessibilityIdentifier("HomeInProgressColumn")
    }

    /// Quiet count only — the column title already names the source.
    private func inProgressDetail(_ board: HomeBoard) -> String? {
        guard board.jiraHealth.retainsContent else { return nil }
        return "\(board.inProgressTickets.count)"
    }

    private func inProgressCard(
        _ ticket: JiraTicketSummary,
        sessions: [ConsoleSession],
        index: Int
    ) -> some View {
        let hasLiveSession = HomeStorySessionMatcher.sessionID(for: ticket, in: sessions) != nil
        let isLaunching = model.launchingTicketKeys.contains(ticket.key)
        let actionLabel: String
        if isLaunching {
            actionLabel = "Starting…"
        } else if hasLiveSession {
            actionLabel = "Open session"
        } else if boardHealthIsReadyForLaunch {
            actionLabel = "Start session"
        } else {
            actionLabel = "Refresh to start"
        }

        return HomeBoardTicketCard(
            ticket: ticket,
            stateLine: nil,
            actionLabel: actionLabel,
            isLaunching: isLaunching
        ) {
            guard !isLaunching else { return }
            Task {
                await model.continueTicket(ticket, sessions: sessions)
            }
        }
        .accessibilityIdentifier("HomeInProgressCard.\(index)")
    }

    /// Only `.current` Jira data may launch a new session; retained data may
    /// open an existing one but the click degrades to a refresh request.
    private var boardHealthIsReadyForLaunch: Bool {
        HomeBoardBuilder.canStartSession(jiraStatus: model.snapshot().jiraStatus)
    }

    // MARK: Review

    private func reviewColumn(_ board: HomeBoard) -> some View {
        HomeBoardColumn(
            title: "Review",
            detail: reviewDetail(board),
            health: board.reviewHealth,
            recovery: gitLabRecovery(for: board.reviewHealth),
            onRecovery: { recover(gitLabRecovery(for: board.reviewHealth)) },
            statusMessage: reviewScanStatus,
            content: {
                if board.reviewQueue.isEmpty {
                    if board.reviewHealth == .ready {
                        HomeBoardPlaceholderCard(
                            title: "No merge requests to review",
                            accessibilityIdentifier: "HomeReviewEmptyPlaceholder"
                        )
                    }
                } else {
                    ForEach(
                        Array(board.reviewQueue.prefix(Self.maxReviewRequests).enumerated()),
                        id: \.element.id
                    ) { index, item in
                        HomeBoardReviewRequestCard(
                            item: item,
                            stateLabel: reviewStateLabel(item),
                            disposition: reviewScanScheduler?.dispositions?.disposition(for: item),
                            actionLabel: "Open review"
                        ) {
                            model.openReview(item)
                        }
                        .accessibilityIdentifier("HomeReviewCard.\(index)")
                    }

                    if board.reviewQueue.count > Self.maxReviewRequests {
                        Text("More merge requests to review")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .accessibilityIdentifier("HomeReviewOverflowFooter")
                    }
                }
            },
            accessory: {
                HStack(spacing: 6) {
                    if isReviewRefreshing || reviewScanScheduler?.dispositions?.isClassifying == true {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityLabel(isReviewRefreshing ? "Checking GitLab" : "Classifying review dispositions")
                    }
                    HomeRefreshAgeLabel(
                        lastRefresh: model.snapshot().reviewStatus.lastSuccessfulExtraction
                    )
                    .accessibilityIdentifier("HomeReviewRefreshAge")

                    Button {
                        reviewScanScheduler?.scanNow()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 18, weight: .regular))
                            .frame(minWidth: 28, minHeight: 28)
                            .contentShape(Rectangle())
                    }
                    .help("Refresh reviews")
                    .disabled(isReviewRefreshing || reviewScanScheduler == nil)
                    .accessibilityIdentifier("HomeReviewRefreshButton")
                }
            }
        )
        .accessibilityIdentifier("HomeReviewColumn")
    }

    private var isReviewRefreshing: Bool {
        reviewScanScheduler?.isScanning == true || MergeRequestListSession.shared.controller(for: .reviewsRequested).isRefreshing
    }

    private var reviewScanStatus: String? {
        if isReviewRefreshing { return "Checking GitLab…" }
        let controller = MergeRequestListSession.shared.controller(for: .reviewsRequested)
        if controller.lastRefreshTimedOut {
            return MRReviewScanOutcome.timedOut.message
        }
        let sourceMessage: String?
        // Live source state wins over a previous scan outcome, especially
        // when sign-in recovery finishes after the scheduler has returned.
        switch controller.state {
        case .unconfigured: sourceMessage = MRReviewScanOutcome.unconfigured.message
        case .authenticationRequired: sourceMessage = MRReviewScanOutcome.signInRequired.message
        case .unsupportedPage: sourceMessage = MRReviewScanOutcome.unsupportedPage.message
        case .extractionFailed: sourceMessage = MRReviewScanOutcome.failed.message
        case .stale(_, _, let reason): sourceMessage = "\(reason.reasonText). Showing previous cards; refresh to retry."
        case .loaded(let items, _): sourceMessage = MRReviewScanOutcome.refreshed(items.count).message
        case .empty: sourceMessage = MRReviewScanOutcome.refreshed(0).message
        case .loadingPage, .extracting: sourceMessage = MRReviewScanOutcome.cancelled.message
        }
        let deferred = reviewScanScheduler?.lastOutcome == .deferred
            && (reviewScanScheduler?.lastScanStartedAt ?? .distantPast) >= (controller.state.refreshedAt ?? .distantPast)
        let message = [deferred ? MRReviewScanOutcome.deferred.message : sourceMessage, reviewScanScheduler?.dispositions?.message]
            .compactMap { $0 }.joined(separator: " ")
        return message.isEmpty ? nil : message
    }

    private func reviewStateLabel(_ item: MergeRequestSummary) -> String {
        if let disposition = reviewScanScheduler?.dispositions?.disposition(for: item) {
            return "AI: \(disposition.rawValue)"
        }
        return AttentionChannel.awaitingAuthorReviewState(item.reviewDisplayState)?.label
            ?? item.reviewDisplayState ?? "Review requested"
    }

    /// Quiet count only — the column title already names the source.
    private func reviewDetail(_ board: HomeBoard) -> String? {
        guard board.reviewHealth.retainsContent else { return nil }
        return "\(board.reviewQueue.count)"
    }

    // MARK: - Source recovery

    private func recoveryCard(_ recovery: HomeBoardRecovery?) -> some View {
        Group {
            if let recovery {
                HomeBoardRecoveryCard(recovery: recovery, action: { recover(recovery) })
            }
        }
    }

    private func jiraRecovery(for health: HomeBoardHealth) -> HomeBoardRecovery? {
        switch health {
        case .unconfigured: return .setUpJira
        case .signedOut: return nil // JIRA sign-in is surfaced by the Next story slot
        case .unavailable: return .openJira
        case .ready, .updating, .stale, .loading: return nil
        }
    }

    private func gitLabRecovery(for health: HomeBoardHealth) -> HomeBoardRecovery? {
        switch health {
        case .unconfigured: return .setUpGitLab
        case .signedOut: return .signInGitLab // Next no longer shows GitLab; Review owns sign-in
        case .unavailable: return .openGitLab
        case .ready, .updating, .stale, .loading: return nil
        }
    }

    private func recover(_ recovery: HomeBoardRecovery?) {
        switch recovery {
        case .setUpJira, .setUpGitLab:
            model.openSettings()
        case .signInJira, .openJira:
            model.openJiraSource()
        case .signInGitLab, .openGitLab:
            model.openGitLabSource()
        case nil:
            break
        }
    }

    // MARK: - Wiring

    private func installActionSeams() {
        model.selectSessionHandler = { [sessionStore] id in
            sessionStore?.select(sessionID: id)
            ConsoleNavigation.showSessions()
        }
        model.startSessionHandler = { [launchCoordinator] key, title, url in
            await launchCoordinator.beginJiraTicketLaunch(
                key: key,
                title: title,
                url: url,
                displayName: NewTicketSessionNaming.displayName(forJiraKey: key)
            )
        }
        model.refreshJiraHandler = { [sources] in
            sources.refreshJira()
        }
        // Entry-time staleness pass for the Review column goes through the
        // scan scheduler so its in-flight guard and retained-page-away
        // protections apply.
        sources.refreshReviewsHandler = { [reviewScanScheduler] in
            reviewScanScheduler?.scanOnAppearance()
        }
    }
}

#Preview("Home Board") {
    HomeView()
        .environment(SessionStore())
        .environment(SessionLaunchCoordinator(store: SessionStore(), workspaceStore: SessionWorkspaceStore()))
        .frame(width: 900, height: 560)
}
