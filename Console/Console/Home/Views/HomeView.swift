import SwiftUI

/// Home reads the Jira panel and the memory-only glab AI review queue.
struct HomeView: View {
    @AppStorage("webViewJiraURL") private var webViewJiraURL: String = ""
    @Environment(SessionStore.self) private var sessionStore: SessionStore?
    @Environment(SessionLaunchCoordinator.self) private var launchCoordinator
    @Environment(MRReviewScanScheduler.self) private var reviewScanScheduler: MRReviewScanScheduler?

    @State private var sources: HomeSourcesCoordinator
    @State private var model: HomeBoardModel
    @State private var launchingReviews: Set<URL> = []

    init() {
        let jiraController = JiraWebSession.shared.panelController
        let reviewsController = MRReviewScanController.shared
        _sources = State(initialValue: HomeSourcesCoordinator(
            jiraController: jiraController,
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
            .alert("Review scan unavailable", isPresented: Binding(
                get: { reviewScanScheduler?.source.manualError != nil },
                set: { if !$0 { reviewScanScheduler?.source.manualError = nil } }
            )) {
                Button("OK") { reviewScanScheduler?.source.manualError = nil }
            } message: {
                Text(reviewScanScheduler?.source.manualError ?? "")
            }
    }

    // MARK: - Board

    private var board: some View {
        let snapshot = model.snapshot()
        let board = HomeBoardBuilder.build(snapshot)
        let sessions = sessionStore?.sessions ?? []

        return HStack(alignment: .top, spacing: 12) {
            nextColumn(board, sessions: sessions)
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
    private func nextColumn(_ board: HomeBoard, sessions: [ConsoleSession]) -> some View {
        HomeBoardColumn(
            title: "Next Story",
            detail: nil,
            health: .ready,
            content: {
                nextStorySlot(board, sessions: sessions)
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
    private func nextStorySlot(_ board: HomeBoard, sessions: [ConsoleSession]) -> some View {
        switch board.jiraHealth {
        case .ready:
            if let story = board.nextStory {
                nextStoryCard(story, sessions: sessions)
            } else {
                HomeBoardPlaceholderCard(
                    title: "No story",
                    detail: "Open JIRA to pick something new.",
                    accessibilityIdentifier: "HomeNextNoStoryPlaceholder"
                )
            }
        case .updating, .stale:
            if let story = board.nextStory {
                nextStoryCard(story, sessions: sessions)
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

    /// The Next story card: open the issue in JIRA, or start a session on it.
    /// Starting routes through the shared launch journey — it opens the
    /// story's live session when one exists, launches on current data, and
    /// requests a refresh against stale data.
    private func nextStoryCard(
        _ story: JiraTicketSummary,
        sessions: [ConsoleSession]
    ) -> some View {
        let isLaunching = model.launchingTicketKeys.contains(story.key)
        return HomeBoardTicketCard(
            ticket: story,
            stateLine: story.status,
            bottomActions: [
                HomeCardAction(label: "Open story") { model.openStory(story) },
                HomeCardAction(label: isLaunching ? "Starting…" : "Start story") {
                    guard !isLaunching else { return }
                    Task {
                        await model.continueTicket(story, sessions: sessions)
                    }
                }
            ],
            cardAction: { model.openStory(story) },
            isLaunching: isLaunching
        )
        .accessibilityIdentifier("HomeNextStoryCard")
    }

    // MARK: In Progress

    /// Display limits apply after the full queues have been ordered.
    static let maxInProgressStories = 9

    static let maxReviewRequests = 9

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
        let inReview = AttentionChannel.forTicketStatus(ticket.status) == .inFlight
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
        let primaryJourney: () -> Void = {
            guard !isLaunching else { return }
            Task {
                await model.continueTicket(ticket, sessions: sessions)
            }
        }

        var bottomActions: [HomeCardAction] = []
        if !inReview {
            bottomActions.append(HomeCardAction(label: actionLabel, handler: primaryJourney))
        }
        bottomActions.append(HomeCardAction(label: "Open in JIRA") { model.openStory(ticket) })
        bottomActions.append(HomeCardAction(label: "Open in GitLab") { model.openGitLabSource() })

        return HomeBoardTicketCard(
            ticket: ticket,
            stateLine: inReview ? ticket.status : nil,
            bottomActions: bottomActions,
            cardAction: inReview ? { model.openStory(ticket) } : primaryJourney,
            isLaunching: isLaunching
        )
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
            recovery: board.reviewHealth == .unconfigured ? .setUpGitLab : nil,
            onRecovery: { model.openSettings() },
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
                            isLaunching: launchingReviews.contains(item.id),
                            hasReviewSession: reviewSession(for: item) != nil,
                            canOpenJira: jiraURL(for: item) != nil,
                            open: { model.openReview(item) },
                            openJira: {
                                guard let url = jiraURL(for: item) else { return }
                                HomeBoardModel.executeNavigation(.openJiraIssue(url: url))
                            },
                            startReview: { startReview(item) }
                        )
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
                    if isReviewRefreshing {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityLabel("Triaging GitLab reviews")
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
        reviewScanScheduler?.isScanning == true
    }

    private var reviewScanStatus: String? {
        if isReviewRefreshing { return "Triaging GitLab reviews…" }
        return reviewScanScheduler?.source.message ?? reviewScanScheduler?.lastOutcome?.message
    }

    private func startReview(_ item: MergeRequestSummary) {
        if let session = reviewSession(for: item) {
            model.selectSession(session.id)
            return
        }
        guard let iid = item.iidText, !launchingReviews.contains(item.id) else { return }
        launchingReviews.insert(item.id)
        Task {
            defer { launchingReviews.remove(item.id) }
            await launchCoordinator.beginMergeRequestReview(iid: iid, title: item.title, url: item.mergeRequestURL)
        }
    }

    private func reviewSession(for item: MergeRequestSummary) -> ConsoleSession? {
        HomeStorySessionMatcher.reviewSession(for: item.mergeRequestURL, in: sessionStore?.sessions ?? [])
    }

    private func jiraURL(for item: MergeRequestSummary) -> URL? {
        if let session = reviewSession(for: item),
           let url = HomeStorySessionMatcher.jiraURL(for: session, configuredURL: webViewJiraURL) {
            return url
        }
        guard let key = item.jiraIssueKey ?? JiraSourceContext.issueKey(in: item.title) else { return nil }
        if let ticket = model.snapshot().jiraTickets.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) {
            return ticket.issueURL
        }
        return JiraSourceContext.issueURL(key: key, configuredURL: webViewJiraURL)
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
        // The AI scheduler owns review staleness and deduplicates refreshes.
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
