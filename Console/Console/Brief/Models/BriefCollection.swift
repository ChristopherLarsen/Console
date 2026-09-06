import Foundation

/// One workspace to scan for attributed commit activity.
struct BriefCollectionSource: Equatable, Sendable {
    var workspaceID: UUID? = nil
    var path: String
    var displayName: String
    var identity: BriefAuthorIdentity
}

/// Local Git query: selected identities, half-open authored-date range, and
/// the calendar whose day boundaries define that range.
struct BriefCollectionRequest: Sendable {
    var sources: [BriefCollectionSource]
    var rangeStart: Date
    var rangeEnd: Date
    var calendar: Calendar

    var interval: DateInterval {
        DateInterval(start: rangeStart, end: rangeEnd)
    }

    init(sources: [BriefCollectionSource],
         rangeStart: Date,
         rangeEnd: Date,
         calendar: Calendar) {
        self.sources = sources
        self.rangeStart = rangeStart
        self.rangeEnd = max(rangeStart, rangeEnd)
        self.calendar = calendar
    }

    init(sources: [BriefCollectionSource],
         range: BriefDateRangeSelection,
         briefDay: Date,
         calendar: Calendar) {
        let interval = range.interval(relativeTo: briefDay, calendar: calendar)
        self.init(
            sources: sources,
            rangeStart: interval.start,
            rangeEnd: interval.end,
            calendar: calendar
        )
    }
}

/// A repository that was actually opened while collecting activity.
struct BriefSourceRepository: Codable, Equatable, Sendable {
    var displayName: String
    var identity: String
}

/// Attributed activities plus the repositories that were scanned.
struct BriefCollectionResult: Equatable, Sendable {
    var activities: [CommitActivity]
    var sourceRepositories: [BriefSourceRepository]

    static let empty = BriefCollectionResult(activities: [], sourceRepositories: [])
}

/// Reads `user.name` / `user.email` from the Git configuration that applies
/// to a workspace folder. Local-only; no network.
protocol BriefIdentityReading: Sendable {
    func readConfiguredIdentity(at path: String) async -> BriefAuthorIdentity
}
