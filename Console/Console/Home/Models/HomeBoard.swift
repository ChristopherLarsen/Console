import Foundation

/// Value inputs for the Home work board, gathered from the live panel
/// controllers. Kept free of views, WebKit, and terminals so every rule on
/// the board is unit-testable.
struct HomeBoardSnapshot: Equatable, Sendable {
    var jiraTickets: [JiraTicketSummary] = []
    var jiraStatus = HomeSourceStatus(check: .unconfigured)
    var reviewItems: [MergeRequestSummary] = []
    var reviewStatus = HomeSourceStatus(check: .unconfigured)
}

/// One presentation health for a whole column (or one Next slot). Derived
/// only from `HomeSourceStatus`; retained data upgrades pending/failed to
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
        case .jira: return "Sign in to JIRA"
        case .gitlab: return "Sign in to GitLab"
        }
    }
}

/// The three-column Home board: the parked stories to start next, the
/// in-progress stories, and the review queue ordered most-urgent-first.
/// Selection, filtering, and ordering are pure; the view only renders.
struct HomeBoard: Equatable, Sendable {
    var jiraHealth = HomeBoardHealth.unconfigured
    var reviewHealth = HomeBoardHealth.unconfigured

    /// Parked stories the user could start next, most preferred first.
    var nextStories: [JiraTicketSummary] = []
    /// Parked tickets whose host status is exactly "Next Up"; Backlog and
    /// every other parked status never count.
    var nextUpCount = 0
    /// Every review-request row, most urgent first. The most urgent row is
    /// the "next MR to review".
    var reviewQueue: [MergeRequestSummary] = []
    /// Stories whose host status is actively in progress or in review,
    /// source order.
    var inProgressTickets: [JiraTicketSummary] = []

    /// The one parked story the user should start next.
    var nextStory: JiraTicketSummary? { nextStories.first }
}

enum HomeBoardBuilder {
    /// Column/slot health from one source status. Retained data (a non-empty
    /// last extraction) upgrades pending and failed states to keep-last-known;
    /// only a real empty current list produces a true empty state.
    static func health(for status: HomeSourceStatus, hasRetained: Bool) -> HomeBoardHealth {
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
            board.nextStories = nextStories(in: snapshot.jiraTickets)
            board.nextUpCount = snapshot.jiraTickets.filter { isNextUp($0) }.count
            board.inProgressTickets = snapshot.jiraTickets.filter {
                switch AttentionChannel.forTicketStatus($0.status) {
                case .active, .inFlight, .testing: return true
                default: return false
                }
            }
        }
        if board.reviewHealth.retainsContent {
            board.reviewQueue = reviewQueue(in: snapshot.reviewItems)
        }
        return board
    }

    /// Every parked story worth starting, best first. Unknown status
    /// vocabulary parks, so an unrecognized label stays eligible to start.
    /// Preference cascade, in order:
    ///   1. Status tier — "Next Up" outranks every other parked status
    ///      ("Backlog", "To Do", unrecognized).
    ///   2. Type tier within one status — Bug issues outrank everything
    ///      else; Features rank last; an unknown type sits in between.
    ///   3. Host order breaks remaining ties.
    static func nextStories(in tickets: [JiraTicketSummary]) -> [JiraTicketSummary] {
        tickets
            .filter { AttentionChannel.forTicketStatus($0.status) == .parked }
            .sorted { lhs, rhs in
                let left = nextStoryPreference(lhs)
                let right = nextStoryPreference(rhs)
                if left.statusTier != right.statusTier { return left.statusTier < right.statusTier }
                if left.typeTier != right.typeTier { return left.typeTier < right.typeTier }
                return lhs.sourceOrder < rhs.sourceOrder
            }
    }

    /// The single best parked story: the head of `nextStories(in:)`.
    static func nextStoryTicket(in tickets: [JiraTicketSummary]) -> JiraTicketSummary? {
        nextStories(in: tickets).first
    }

    /// True only for the exact host status "Next Up".
    static func isNextUp(_ ticket: JiraTicketSummary) -> Bool {
        normalizedText(ticket.status) == "next up"
    }

    /// Preference rank for one parked ticket: lower wins. Status "Next Up"
    /// is tier 0, everything else tier 1. Within a tier, Bug issues are
    /// preferred (0), Features are deprioritized last (2), and any other or
    /// unknown type keeps host order in between (1).
    private static func nextStoryPreference(_ ticket: JiraTicketSummary) -> (statusTier: Int, typeTier: Int) {
        let statusTier = isNextUp(ticket) ? 0 : 1
        let typeTier: Int
        switch normalizedText(ticket.issueType) {
        case let type? where type.hasPrefix("bug"): typeTier = 0
        case let type? where type.hasPrefix("feature"): typeTier = 2
        default: typeTier = 1
        }
        return (statusTier, typeTier)
    }

    private static func normalizedText(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The Review column's queue: every review-request row, most urgent
    /// first. Urgency cascade, in order:
    ///   1. Rows the user has already reviewed — the host shows "Changes
    ///      requested" / "Discussion" — mean a re-review is coming, so they
    ///      outrank rows not yet reviewed. Console reads host-rendered states
    ///      only and cannot confirm who reviewed; this tiering is a disclosed
    ///      approximation.
    ///   2. Lower target versions first, numerically ("1.9" before "1.10");
    ///      a row with no target version sorts last.
    ///   3. Older rows first (by the host-rendered timestamp).
    ///   4. Host order breaks remaining ties.
    static func reviewQueue(
        in items: [MergeRequestSummary],
        now: Date = Date()
    ) -> [MergeRequestSummary] {
        items.sorted { lhs, rhs in
            if let left = lhs.triageCategory, let right = rhs.triageCategory {
                if left != right { return left.priority < right.priority }
                return lhs.sourceOrder < rhs.sourceOrder
            }
            let lhsAwaiting = AttentionChannel.awaitingAuthorReviewState(lhs.reviewDisplayState) != nil
            let rhsAwaiting = AttentionChannel.awaitingAuthorReviewState(rhs.reviewDisplayState) != nil
            if lhsAwaiting != rhsAwaiting { return lhsAwaiting }

            switch compareTargetVersions(lhs.targetVersionText, rhs.targetVersionText) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: break
            }

            switch olderFirst(lhs.updatedText, rhs.updatedText, now: now) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: break
            }

            return lhs.sourceOrder < rhs.sourceOrder
        }
    }

    /// Older first by the host-rendered timestamp; an unparseable or missing
    /// timestamp is less urgent than a known one, and two unknowns tie.
    private static func olderFirst(
        _ lhs: String?,
        _ rhs: String?,
        now: Date
    ) -> ComparisonResult {
        let lhsDate = RelativeAge.approximateDate(from: lhs, now: now)
        let rhsDate = RelativeAge.approximateDate(from: rhs, now: now)
        switch (lhsDate, rhsDate) {
        case let (l?, r?):
            if l == r { return .orderedSame }
            return l < r ? .orderedAscending : .orderedDescending
        case (_?, nil): return .orderedAscending
        case (nil, _?): return .orderedDescending
        case (nil, nil): return .orderedSame
        }
    }

    /// Urgency order for host-rendered target versions: lower first,
    /// numerically aware so "1.10" sorts after "1.9" and "24.10" after
    /// "24.9". Unparseable segments fall back to case-insensitive text
    /// order; a missing target version sorts last.
    static func compareTargetVersions(_ lhs: String?, _ rhs: String?) -> ComparisonResult {
        switch (lhs.flatMap(nonEmpty), rhs.flatMap(nonEmpty)) {
        case (nil, nil): return .orderedSame
        case (_, nil): return .orderedAscending
        case (nil, _): return .orderedDescending
        case let (l?, r?): return compareVersionTexts(l, r)
        }
    }

    private static func compareVersionTexts(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsParts = versionComponents(lhs)
        let rhsParts = versionComponents(rhs)
        for index in 0..<max(lhsParts.count, rhsParts.count) {
            let lhsPart = index < lhsParts.count ? lhsParts[index] : nil
            let rhsPart = index < rhsParts.count ? rhsParts[index] : nil
            switch (lhsPart, rhsPart) {
            case (nil, nil): continue
            case (nil, _): return .orderedAscending
            case (_, nil): return .orderedDescending
            case let (l?, r?):
                if let lNumber = Int(l), let rNumber = Int(r), lNumber != rNumber {
                    return lNumber < rNumber ? .orderedAscending : .orderedDescending
                }
                if l.caseInsensitiveCompare(r) != .orderedSame {
                    return l.caseInsensitiveCompare(r)
                }
            }
        }
        return .orderedSame
    }

    /// Splits "v24.10" into ["24", "10"]; "M120" stays one text segment.
    private static func versionComponents(_ raw: String) -> [String] {
        var body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = body.first, first == "v" || first == "V" {
            body = String(body.dropFirst())
        }
        return body
            .split(whereSeparator: { $0 == "." || $0 == "-" })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Starting a brand-new session requires current Jira data; retained
    /// (stale) data may open existing sessions but must never launch work
    /// against a possibly-moved story.
    static func canStartSession(jiraStatus: HomeSourceStatus) -> Bool {
        jiraStatus.check == .current
    }
}
