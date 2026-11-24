import SwiftUI

/// Home reads the Jira panel and the memory-only glab AI review queue.
struct HomeView: View {
    @AppStorage("webViewJiraURL") private var webViewJiraURL: String = ""
    @Environment(SessionStore.self) private var sessionStore: SessionStore?
    @Environment(SessionLaunchCoordinator.self) private var launchCoordinator
    @Environment(MRReviewScanScheduler.self) private var reviewScanScheduler: MRReviewScanScheduler?
    @Environment(MRResponsePrepController.self) private var responsePrep: MRResponsePrepController?
    @Environment(StorySynopsisController.self) private var synopses: StorySynopsisController?
    @State private var synopsisTicket: JiraTicketSummary?

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
            // Synopses leave the cache once their story is In Progress (or off
            // the list), whenever a JIRA extraction lands.
            .onChange(of: model.snapshot().jiraStatus.lastSuccessfulExtraction, initial: true) {
                pruneSynopses()
            }
            .sheet(item: $synopsisTicket) { ticket in
                if let synopses {
                    StorySynopsisSheet(ticket: ticket, controller: synopses) { model.openStory(ticket) }
                }
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

        // The Orchestrator section takes only the room its cards need, up to
        // two rows; more than that scrolls inside it.
        return GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 10) {
                decisionCards
                    .frame(height: min(orchestratorSectionHeight(width: geometry.size.width), geometry.size.height * 0.6))
                // Next up holds at most three cards and Review often holds
                // many, so the stories stack in the left third and Review
                // takes the other two thirds, two cards wide.
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 10) {
                        nextColumn(board, sessions: sessions)
                        inProgressColumn(board, sessions: sessions)
                    }
                    .frame(width: max(0, (geometry.size.width - 12) / 3))
                    reviewColumn(board)
                }
            }
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

    /// What the Orchestrator is waiting on leads the board: it is the one
    /// thing here only the user can move. The untitled section sits on
    /// a very light grey ground; its cards keep the shared white surface.
    private var decisionCards: some View {
        let waiting = sessionStore.map { $0.proposedPlan != nil || !$0.openDecisions.isEmpty } ?? false
        return VStack(alignment: .leading, spacing: 0) {
            if let sessionStore, waiting {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: Self.orchestratorCardMinWidth), spacing: HomeCardMetrics.listGap, alignment: .top)],
                        alignment: .leading, spacing: HomeCardMetrics.listGap
                    ) {
                        if let plan = sessionStore.proposedPlan {
                            HomePlanCard(
                                plan: plan,
                                ownerName: { id in sessionStore.sessions.first { $0.id == id }?.name },
                                approve: {
                                    do {
                                        try sessionStore.approveProposedPlan()
                                    } catch {
                                        launchCoordinator.report(failure: "The plan could not be approved. It may have changed; check the Orchestrator.")
                                    }
                                },
                                discuss: { discuss(decision: nil) }
                            )
                        }
                        ForEach(sessionStore.openDecisions, id: \.id) { decision in
                            let session = decision.session.flatMap(UUID.init(uuidString:)).flatMap { id in
                                sessionStore.sessions.first { $0.id == id }
                            }
                            HomeDecisionCard(
                                decision: decision,
                                sessionName: session?.name,
                                discuss: { discuss(decision: decision.id) },
                                openMergeRequest: session.flatMap(mergeRequestURL(for:)).map { url in
                                    { HomeBoardModel.executeNavigation(.openMergeRequest(url: url)) }
                                },
                                openJira: session.flatMap(storyURL(for:)).map { url in
                                    { HomeBoardModel.executeNavigation(.openJiraIssue(url: url)) }
                                }
                            ) { option in
                                do {
                                    try sessionStore.answerDecision(id: decision.id, option: option)
                                } catch {
                                    launchCoordinator.report(failure: "That decision could not be saved. It may already be answered.")
                                }
                            }
                        }
                    }
                    .padding(8)
                    .accessibilityIdentifier("HomeDecisions")
                }
            } else {
                Text("The Orchestrator is not waiting on you.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.97)))
        .accessibilityIdentifier("HomeOrchestratorSection")
    }

    private static let orchestratorCardMinWidth: CGFloat = 300

    /// The session's most recently linked merge request.
    private func mergeRequestURL(for session: ConsoleSession) -> URL? {
        session.artifacts.last(where: { $0.kind == .gitlabMergeRequest })?.url
    }

    /// The session's JIRA story, resolved the same way the Sessions header does.
    private func storyURL(for session: ConsoleSession) -> URL? {
        HomeStorySessionMatcher.jiraURL(
            for: session, configuredURL: webViewJiraURL, reviewItems: MRReviewScanController.shared.items
        )
    }

    /// One or two rows of cards, from how many cards there are
    /// and how many fit across; a single line when nothing is waiting.
    private func orchestratorSectionHeight(width: CGFloat) -> CGFloat {
        let cards = (sessionStore?.openDecisions.count ?? 0) + (sessionStore?.proposedPlan == nil ? 0 : 1)
        guard cards > 0 else { return 28 }
        let gap = HomeCardMetrics.listGap
        let perRow = max(1, Int((width - 16 + gap) / (Self.orchestratorCardMinWidth + gap)))
        let rows = CGFloat(min(2, (cards + perRow - 1) / perRow))
        return rows * HomeOrchestratorCardMetrics.height + (rows - 1) * gap + 16
    }

    /// Switches to the Orchestrator and tells it which card the user opened.
    private func discuss(decision id: Int?) {
        if let orchestrator = sessionStore?.discussWithOrchestrator(decision: id) {
            model.selectSession(orchestrator)
        } else {
            launchCoordinator.report(failure: "The Orchestrator is not running. Start it from the sidebar to discuss this.")
        }
    }

    // MARK: Next

    /// Next holds the parked stories worth starting, best first. The column
    /// itself always renders content; each card owns its state presentation.
    private func nextColumn(_ board: HomeBoard, sessions: [ConsoleSession]) -> some View {
        HomeBoardColumn(
            title: "Next up",
            detail: nextDetail(board),
            health: .ready,
            fitsContent: true,
            content: {
                nextStorySlot(board, sessions: sessions)
            },
            accessory: {
                HStack(spacing: 6) {
                    // While the source refreshes, the age label gives way to
                    // the spinner: a stale "last refresh" is noise mid-check.
                    if isJiraRefreshing {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityLabel("Refreshing Jira")
                    } else {
                        HomeRefreshAgeLabel(
                            lastRefresh: model.snapshot().jiraStatus.lastSuccessfulExtraction
                        )
                        .accessibilityIdentifier("HomeNextRefreshAge")
                    }

                    UnfocusedIconButton(
                        systemName: "arrow.clockwise",
                        help: "Refresh Jira",
                        identifier: "HomeNextRefreshButton",
                        action: { sources.refreshJira() }
                    )
                }
            }
        )
        .accessibilityIdentifier("HomeNextColumn")
    }

    /// Quiet count of stories whose host status is Next Up.
    private func nextDetail(_ board: HomeBoard) -> String? {
        guard board.jiraHealth.retainsContent else { return nil }
        return "(\(board.nextUpCount))"
    }

    @ViewBuilder
    private func nextStorySlot(_ board: HomeBoard, sessions: [ConsoleSession]) -> some View {
        switch board.jiraHealth {
        case .ready:
            if board.nextStories.isEmpty {
                HomeBoardPlaceholderCard(
                    title: "No story",
                    detail: "Open JIRA to pick something new.",
                    accessibilityIdentifier: "HomeNextNoStoryPlaceholder"
                )
            } else {
                nextStoryCards(board, sessions: sessions)
            }
        case .updating, .stale:
            if !board.nextStories.isEmpty {
                nextStoryCards(board, sessions: sessions)
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

    @ViewBuilder
    private func nextStoryCards(_ board: HomeBoard, sessions: [ConsoleSession]) -> some View {
        ForEach(
            Array(board.nextStories.prefix(Self.maxNextStories).enumerated()),
            id: \.element.key
        ) { index, story in
            nextStoryCard(story, sessions: sessions, index: index)
        }

        if board.nextUpCount > Self.maxNextStories {
            Text("There are \(board.nextUpCount) Next Up stories")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 6)
                .accessibilityIdentifier("HomeNextOverflowFooter")
        }
    }

    /// A Next up card: open the issue in JIRA, or start a session on it.
    /// Starting routes through the shared launch journey — it opens the
    /// story's live session when one exists, launches on current data, and
    /// requests a refresh against stale data.
    private func nextStoryCard(
        _ story: JiraTicketSummary,
        sessions: [ConsoleSession],
        index: Int
    ) -> some View {
        let isLaunching = model.launchingTicketKeys.contains(story.key)
        return HomeBoardTicketCard(
            ticket: story,
            stateLine: story.status,
            bottomActions: [
                HomeCardAction(label: "Open in JIRA", kind: .jira) { model.openStory(story) },
                HomeCardAction(label: "Review Synopsis") { showSynopsis(story) },
                HomeCardAction(label: isLaunching ? "Starting…" : "Start story") {
                    guard !isLaunching else { return }
                    Task {
                        await model.continueTicket(
                            story,
                            sessions: sessions,
                            associations: sessionStore?.associations,
                            agent: SessionStore.newStoryAgentName
                        )
                    }
                }
            ],
            cardAction: { model.openStory(story) },
            isLaunching: isLaunching
        )
        .accessibilityIdentifier("HomeNextStoryCard.\(index)")
    }

    private func showSynopsis(_ story: JiraTicketSummary) {
        guard let synopses else { return }
        synopses.request(story)
        synopsisTicket = story
    }

    private func pruneSynopses() {
        guard let synopses else { return }
        let snapshot = model.snapshot()
        let board = HomeBoardBuilder.build(snapshot)
        synopses.prune(inProgress: board.inProgressTickets,
                       currentTickets: snapshot.jiraStatus.check == .current ? snapshot.jiraTickets : nil)
    }

    // MARK: In Progress

    /// Display limits apply after the full queues have been ordered.
    static let maxNextStories = 3

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
                    // While the source refreshes, the age label gives way to
                    // the spinner: a stale "last refresh" is noise mid-check.
                    if isJiraRefreshing {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityLabel("Refreshing Jira")
                    } else {
                        HomeRefreshAgeLabel(
                            lastRefresh: model.snapshot().jiraStatus.lastSuccessfulExtraction
                        )
                        .accessibilityIdentifier("HomeInProgressRefreshAge")
                    }

                    UnfocusedIconButton(
                        systemName: "arrow.clockwise",
                        help: "Refresh Jira",
                        identifier: "HomeInProgressRefreshButton",
                        action: { sources.refreshJira() }
                    )
                }
            }
        )
        .accessibilityIdentifier("HomeInProgressColumn")
    }

    /// Quiet count only — the column title already names the source.
    private func inProgressDetail(_ board: HomeBoard) -> String? {
        guard board.jiraHealth.retainsContent else { return nil }
        return "(\(board.inProgressTickets.count))"
    }

    private func inProgressCard(
        _ ticket: JiraTicketSummary,
        sessions: [ConsoleSession],
        index: Int
    ) -> some View {
        let hasLiveSession = HomeStorySessionMatcher.sessionID(for: ticket, in: sessions, associations: sessionStore?.associations) != nil
        let isLaunching = model.launchingTicketKeys.contains(ticket.key)
        // Testing shares the in-review presentation: verbatim state line, no
        // start-session button, whole-card tap opens the story.
        let channel = AttentionChannel.forTicketStatus(ticket.status)
        let inReview = channel == .inFlight || channel == .testing
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
                await model.continueTicket(ticket, sessions: sessions, associations: sessionStore?.associations)
            }
        }

        var bottomActions: [HomeCardAction] = []
        if !inReview {
            bottomActions.append(HomeCardAction(label: actionLabel, handler: primaryJourney))
        }
        bottomActions.append(HomeCardAction(label: "Open in JIRA", kind: .jira) { model.openStory(ticket) })
        bottomActions.append(HomeCardAction(label: "Open in GitLab", kind: .gitlab) {
            if let url = mergeRequestURL(for: ticket) {
                // Deep-link the GitLab destination to the story's merge
                // request in its own tab; with no known MR, land on GitLab.
                HomeBoardModel.executeNavigation(.openMergeRequest(url: url))
            } else {
                model.openGitLabSource()
            }
        })

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
            pinnedContent: AnyView(responsePrepCards),
            cardColumns: 2,
            content: {
                if board.reviewQueue.isEmpty {
                    if board.reviewHealth == .ready, responsePrep?.items.isEmpty ?? true {
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
                            sessionAvailability: launchCoordinator
                                .reviewSessionResolution(for: item.mergeRequestURL)
                                .hasPreviousSession ? .resume : .start,
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
                    // While the scan refreshes, the age label gives way to
                    // the spinner: a stale "last refresh" is noise mid-check.
                    if isReviewRefreshing {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityLabel("Triaging GitLab reviews")
                    } else {
                        HomeRefreshAgeLabel(
                            lastRefresh: model.snapshot().reviewStatus.lastSuccessfulExtraction
                        )
                        .accessibilityIdentifier("HomeReviewRefreshAge")
                    }

                    UnfocusedIconButton(
                        systemName: "arrow.clockwise",
                        help: "Refresh reviews",
                        identifier: "HomeReviewRefreshButton",
                        isEnabled: !isReviewRefreshing && reviewScanScheduler != nil,
                        action: { reviewScanScheduler?.scanNow() }
                    )
                }
            }
        )
        .accessibilityIdentifier("HomeReviewColumn")
    }

    /// The user's own merge requests with unresolved comments lead the Review
    /// column: Console drafts responses for them in a read-only session.
    @ViewBuilder
    private var responsePrepCards: some View {
        if let responsePrep {
            ForEach(Array(responsePrep.items.enumerated()), id: \.element.id) { index, item in
                HomeBoardResponsePrepCard(
                    item: item,
                    state: responsePrep.state(for: item),
                    canReviewResponse: !launchCoordinator.isOpeningAuthoredMR,
                    open: { HomeBoardModel.executeNavigation(.openMergeRequest(url: item.url)) },
                    reviewResponse: { reviewResponse(item) },
                    prepare: { responsePrep.prepare(item) }
                )
                .accessibilityIdentifier("HomeResponsePrepCard.\(index)")
            }
        }
    }

    /// Continue the MR's original development conversation, reusing its live
    /// terminal or resuming the saved conversation through the shared resolver.
    private func reviewResponse(_ item: AuthoredMRAttention) {
        Task { await launchCoordinator.openAuthoredMR(item) }
    }

    private var isReviewRefreshing: Bool {
        reviewScanScheduler?.isScanning == true
    }

    /// The retained Jira panel is mid-refresh. Both Jira columns track the
    /// same controller instance the board model reads, so this is observable
    /// inside the view body.
    private var isJiraRefreshing: Bool {
        JiraWebSession.shared.panelController.isRefreshing
    }

    private var reviewScanStatus: String? {
        if isReviewRefreshing { return "Triaging GitLab reviews…" }
        return reviewScanScheduler?.source.message ?? reviewScanScheduler?.lastOutcome?.message
    }

    private func startReview(_ item: MergeRequestSummary) {
        // A live review session opens in place; a saved/exited one is resumed
        // by the launch journey, which starts fresh only when nothing prior
        // exists.
        if case let .live(id) = launchCoordinator.reviewSessionResolution(for: item.mergeRequestURL) {
            model.selectSession(id)
            return
        }
        guard let iid = item.iidText, !launchingReviews.contains(item.id) else { return }
        launchingReviews.insert(item.id)
        // Review sessions carry the story's key ("NMA-1234 Review"); MR-only
        // items keep the automatic "Review !<iid>" name. The launch queues
        // /rename, /color purple, then Review !<iid>, each submitted separately.
        let jiraKey = item.jiraIssueKey ?? JiraSourceContext.issueKey(in: item.title)
        Task {
            defer { launchingReviews.remove(item.id) }
            await launchCoordinator.beginMergeRequestReview(
                iid: iid,
                title: item.title,
                url: item.mergeRequestURL,
                displayName: jiraKey.map { "\($0) Review" },
                submitReviewPrompt: true
            )
        }
    }

    private func reviewSession(for item: MergeRequestSummary) -> ConsoleSession? {
        HomeStorySessionMatcher.reviewSession(for: item.mergeRequestURL, in: sessionStore?.sessions ?? [], associations: sessionStore?.associations)
    }

    private func jiraURL(for item: MergeRequestSummary) -> URL? {
        if let catalog = sessionStore?.associations {
            let links = catalog.relatedArtifacts(to: item.mergeRequestURL, kind: .gitlabMergeRequest, workKind: .review)
                .filter { $0.kind == .jiraIssue }
            if !links.isEmpty {
                let urls = Set(links.compactMap { link -> URL? in
                    guard let url = link.url, JiraSourceContext.parseIssueKey(fromURL: url) != nil else { return nil }
                    return url
                })
                if urls.count == 1 { return urls.first }
                // Several stories are linked: the one the merge request
                // itself names is the right one. With no such match the
                // lookup carries on rather than disabling the button.
                if let key = item.jiraIssueKey ?? JiraSourceContext.issueKey(in: item.title),
                   let match = urls.first(where: {
                       JiraSourceContext.parseIssueKey(fromURL: $0)?.caseInsensitiveCompare(key) == .orderedSame
                   }) {
                    return match
                }
            }
        }
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

    /// The merge request associated with an in-progress story, mirroring
    /// `jiraURL(for:)`: the story's session carries an MR artifact when it was
    /// launched from GitLab, otherwise the review list's triage match by Jira
    /// key wins. Nil when no merge request is known for the story.
    private func mergeRequestURL(for ticket: JiraTicketSummary) -> URL? {
        func isForTicket(_ key: String?, _ title: String) -> Bool {
            key?.caseInsensitiveCompare(ticket.key) == .orderedSame
                || JiraSourceContext.issueKey(in: title)?.caseInsensitiveCompare(ticket.key) == .orderedSame
        }
        // The user's own open merge requests: an In Progress story's MR is
        // one they authored, which the review queue never lists.
        let authored = MRReviewScanController.shared.authoredItems
            .filter { isForTicket($0.jiraIssueKey, $0.title) }.map(\.url)

        var linked: [URL] = []
        if let catalog = sessionStore?.associations {
            linked = Array(Set(catalog.relatedArtifacts(to: ticket.issueURL, kind: .jiraIssue, workKind: .implementation)
                .filter { $0.kind == .gitlabMergeRequest }.compactMap(\.url)))
            if linked.count == 1 { return linked[0] }
        }
        if let id = HomeStorySessionMatcher.sessionID(for: ticket, in: sessionStore?.sessions ?? [], associations: sessionStore?.associations),
           let session = sessionStore?.sessions.first(where: { $0.id == id }),
           let artifact = session.artifacts.last(where: { $0.kind == .gitlabMergeRequest }),
           let url = artifact.url {
            return url
        }
        if let url = authored.first(where: linked.contains) ?? authored.first { return url }
        if let item = model.snapshot().reviewItems.first(where: { isForTicket($0.jiraIssueKey, $0.title) }) {
            return item.mergeRequestURL
        }
        // Several merge requests are linked and none is known to be open:
        // the newest is the best guess, and beats landing on GitLab's root.
        return linked.max { (Int($0.lastPathComponent) ?? 0) < (Int($1.lastPathComponent) ?? 0) }
    }

    /// Quiet count only — the column title already names the source.
    private func reviewDetail(_ board: HomeBoard) -> String? {
        guard board.reviewHealth.retainsContent else { return nil }
        return "(\(board.reviewQueue.count))"
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
        model.startSessionHandler = { [launchCoordinator] key, title, url, agent in
            await launchCoordinator.beginJiraTicketLaunch(
                key: key,
                title: title,
                url: url,
                displayName: NewTicketSessionNaming.displayName(forJiraKey: key),
                agent: agent,
                submitStartStoryPrompt: agent == SessionStore.newStoryAgentName
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
