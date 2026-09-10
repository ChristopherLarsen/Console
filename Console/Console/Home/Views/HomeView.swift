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
            title: "Next",
            detail: "JIRA",
            health: .ready,
            content: {
                nextStorySlot(board)
            },
            accessory: {
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
                    ForEach(Array(board.inProgressTickets.enumerated()), id: \.element.key) { index, ticket in
                        inProgressCard(ticket, sessions: sessions, index: index)
                    }
                }
            },
            accessory: {
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
        )
        .accessibilityIdentifier("HomeInProgressColumn")
    }

    private func inProgressDetail(_ board: HomeBoard) -> String? {
        guard board.jiraHealth.retainsContent else { return "JIRA" }
        return "JIRA · \(board.inProgressTickets.count)"
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
            content: {
                if board.reviewQueue.isEmpty {
                    if board.reviewHealth == .ready {
                        HomeBoardPlaceholderCard(
                            title: "No merge requests to review",
                            accessibilityIdentifier: "HomeReviewEmptyPlaceholder"
                        )
                    }
                } else {
                    ForEach(Array(board.reviewQueue.enumerated()), id: \.element.id) { index, item in
                        HomeBoardReviewRequestCard(
                            item: item,
                            stateLabel: AttentionChannel.awaitingAuthorReviewState(item.reviewDisplayState)?.label
                                ?? item.reviewDisplayState
                                ?? "Review requested",
                            actionLabel: "Open review"
                        ) {
                            model.openReview(item)
                        }
                        .accessibilityIdentifier("HomeReviewCard.\(index)")
                    }
                }
            },
            accessory: {
                HStack(spacing: 6) {
                    reviewInfoButton
                    Button {
                        reviewScanScheduler?.scanNow()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 18, weight: .regular))
                            .frame(minWidth: 28, minHeight: 28)
                            .contentShape(Rectangle())
                    }
                    .help("Refresh reviews")
                    .accessibilityIdentifier("HomeReviewRefreshButton")
                }
            }
        )
        .accessibilityIdentifier("HomeReviewColumn")
    }

    private func reviewDetail(_ board: HomeBoard) -> String? {
        guard board.reviewHealth.retainsContent else { return "GitLab" }
        return "GitLab · \(board.reviewQueue.count)"
    }

    /// Discloses the Review column's approximations: Console sees the host's
    /// review state but cannot confirm who reviewed or whether the author
    /// has responded since, and the urgency order reads the host-rendered
    /// timestamp and target version.
    private var reviewInfoButton: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .help(Self.reviewProvenanceText)
            .accessibilityLabel("About the Review column")
            .accessibilityIdentifier("HomeReviewInfo")
    }

    static let reviewProvenanceText =
        "Shows every merge request in your review queue, most urgent first: "
        + "re-reviews before first reviews, lower target versions before higher, older before newer. "
        + "Console cannot confirm who reviewed them or whether the author has responded."

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
            await launchCoordinator.beginJiraTicketLaunch(key: key, title: title, url: url)
        }
        model.refreshJiraHandler = { [sources] in
            sources.refreshJira()
        }
    }
}

#Preview("Home Board") {
    HomeView()
        .environment(SessionStore())
        .environment(SessionLaunchCoordinator(store: SessionStore(), workspaceStore: SessionWorkspaceStore()))
        .frame(width: 900, height: 560)
}
