import Foundation

/// Value inputs for the Home work board, gathered from the live panel
/// controllers. Kept free of views, WebKit, and terminals so every rule on
/// the board is unit-testable.
struct HomeBoardSnapshot: Equatable, Sendable {
    var jiraTickets: [JiraTicketSummary] = []
    var jiraStatus = NextSourceStatus(check: .unconfigured)
    var reviewItems: [MergeRequestSummary] = []
    var reviewStatus = NextSourceStatus(check: .unconfigured)
}

/// One presentation health for a whole column (or one Next slot). Derived
/// only from `NextSourceStatus`; retained data upgrades pending/failed to
/// keep-last-known instead of showing a false zero.
enum HomeBoardHealth: Equatable, Sendable {
    /// Last extraction succeeded; empty states are genuine.
    case ready
    /// In flight with no retained data yet.
    case loading
    /// In flight with retained data still on show.
    case updating
    /// Retained data after a later failure or an unsupported page.
    case stale(reason: String?)
    case unconfigured
    case signedOut
    /// Failed or unsupported with nothing retained: the only honest move is
    /// opening the source.
    case unavailable

    /// True when real cards (possibly empty lists) may render.
    var retainsContent: Bool {
        switch self {
        case .ready, .updating, .stale: return true
        case .loading, .unconfigured, .signedOut, .unavailable: return false
        }
    }
}

/// Which host a column or slot reads; supplies the exact recovery copy.
enum HomeBoardSource: String, Equatable, Sendable {
    case jira
    case gitlab

    var displayName: String {
        switch self {
        case .jira: return "Jira"
        case .gitlab: return "GitLab"
        }
    }

    /// Copy for the card shown when the source has nothing retained and
    /// cannot be checked.
    var openToContinueCopy: String {
        switch self {
        case .jira: return "Open Jira to continue"
        case .gitlab: return "Open GitLab to continue"
        }
    }

    var setUpCopy: String {
        switch self {
        case .jira: return "Set up Jira"
        case .gitlab: return "Set up merge requests"
        }
    }

    var signInCopy: String {
        switch self {
        case .jira, .gitlab: return "Sign in required"
        }
    }
}

/// The three-column Home board: one decided story, one decided review, the
/// in-progress stories, and the review requests where the author owes
/// changes. Selection and filtering are pure; the view only renders.
struct HomeBoard: Equatable, Sendable {
    var jiraHealth = HomeBoardHealth.unconfigured
    var reviewHealth = HomeBoardHealth.unconfigured

    /// The one parked story the user should start next.
    var nextStory: JiraTicketSummary?
    /// The one review-request row the user should review next.
    var nextReview: MergeRequestSummary?
    /// Stories whose host status is actively in progress, source order.
    var inProgressTickets: [JiraTicketSummary] = []
    /// Review-request rows whose review state means the author owes changes.
    var awaitingAuthorRequests: [MergeRequestSummary] = []
}

enum HomeBoardBuilder {
    /// Column/slot health from one source status. Retained data (a non-empty
    /// last extraction) upgrades pending and failed states to keep-last-known;
    /// only a real empty current list produces a true empty state.
    static func health(for status: NextSourceStatus, hasRetained: Bool) -> HomeBoardHealth {
        switch status.check {
        case .current:
            return .ready
        case .stale:
            return .stale(reason: status.failureReason)
        case .pending:
            return hasRetained ? .updating : .loading
        case .unconfigured:
            return .unconfigured
        case .signedOut:
            return .signedOut
        case .failed, .unsupported:
            return hasRetained ? .stale(reason: status.failureReason) : .unavailable
        }
    }

    static func build(_ snapshot: HomeBoardSnapshot) -> HomeBoard {
        var board = HomeBoard()
        board.jiraHealth = health(for: snapshot.jiraStatus, hasRetained: !snapshot.jiraTickets.isEmpty)
        board.reviewHealth = health(for: snapshot.reviewStatus, hasRetained: !snapshot.reviewItems.isEmpty)

        if board.jiraHealth.retainsContent {
            board.nextStory = nextStoryTicket(in: snapshot.jiraTickets)
            board.inProgressTickets = snapshot.jiraTickets.filter {
                AttentionChannel.forTicketStatus($0.status) == .active
            }
        }
        if board.reviewHealth.retainsContent {
            board.nextReview = snapshot.reviewItems.min { $0.sourceOrder < $1.sourceOrder }
            board.awaitingAuthorRequests = awaitingAuthorRequests(in: snapshot.reviewItems)
        }
        return board
    }

    /// The next story to start: the first parked ticket in host order — the
    /// same rule as `NextContextBuilder.firstParkedTicket`. Unknown status
    /// vocabulary parks, so an unrecognized label is eligible to start.
    static func nextStoryTicket(in tickets: [JiraTicketSummary]) -> JiraTicketSummary? {
        tickets
            .filter { AttentionChannel.forTicketStatus($0.status) == .parked }
            .min { $0.sourceOrder < $1.sourceOrder }
    }

    /// Review-request rows whose review state means the author owes changes
    /// ("Changes requested" or "Discussion"), host order preserved. Console
    /// cannot confirm who left the review — this is a disclosed approximation.
    static func awaitingAuthorRequests(in items: [MergeRequestSummary]) -> [MergeRequestSummary] {
        items.filter { AttentionChannel.awaitingAuthorReviewState($0.reviewDisplayState) != nil }
    }

    /// Starting a brand-new session requires current Jira data; retained
    /// (stale) data may open existing sessions but must never launch work
    /// against a possibly-moved story.
    static func canStartSession(jiraStatus: NextSourceStatus) -> Bool {
        jiraStatus.check == .current
    }
}
