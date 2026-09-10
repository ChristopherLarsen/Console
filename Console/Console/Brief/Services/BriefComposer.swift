import Foundation

/// One activity item collected from a workspace repository.
struct CommitActivity: Equatable, Sendable {
    let repositoryName: String
    let repositoryIdentity: String
    let commitHash: String
    let authorEmail: String
    let authorName: String
    let subject: String
    let committedAt: Date

    init(
        repositoryName: String,
        subject: String,
        committedAt: Date,
        repositoryIdentity: String = "",
        commitHash: String = "",
        authorEmail: String = "",
        authorName: String = ""
    ) {
        self.repositoryName = repositoryName
        self.repositoryIdentity = repositoryIdentity
        self.commitHash = commitHash
        self.authorEmail = authorEmail
        self.authorName = authorName
        self.subject = subject
        self.committedAt = committedAt
    }

    /// Canonical repository identity plus commit hash when both are known;
    /// otherwise a display-line key so synthetic fixtures keep working.
    var attributionKey: String {
        let identity = repositoryIdentity.isEmpty ? repositoryName : repositoryIdentity
        if !commitHash.isEmpty {
            return identity.lowercased() + "\n" + commitHash.lowercased()
        }
        return "line:\(BriefComposer.reportLine(for: self))"
    }
}

/// Pure composition of `MorningBrief` content from collected activity.
/// No I/O; unit-testable with synthetic data only.
enum BriefComposer {
    static let lineSeparator = " — "
    static let maxLineLength = 72

    // MARK: - Git log parsing

    /// Full hash, author email, author name, author date, subject.
    static let gitLogFormat = "%H%x00%aE%x00%aN%x00%aI%x00%s"

    /// Parses `git log --pretty=format:%H%x00%aE%x00%aN%x00%aI%x00%s`.
    /// Never runs git itself.
    static func parseGitLogOutput(
        _ output: String,
        repositoryName: String,
        repositoryIdentity: String = ""
    ) -> [CommitActivity] {
        let identity = repositoryIdentity.isEmpty ? repositoryName : repositoryIdentity
        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> CommitActivity? in
                let parts = String(line).split(
                    separator: "\0",
                    maxSplits: 4,
                    omittingEmptySubsequences: false
                )
                guard parts.count == 5 else { return nil }
                let hash = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let email = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                let name = String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let date = parseISODate(String(parts[3])) else { return nil }
                let subject = String(parts[4]).trimmingCharacters(in: .whitespaces)
                guard !hash.isEmpty, !subject.isEmpty else { return nil }
                return CommitActivity(
                    repositoryName: repositoryName,
                    subject: subject,
                    committedAt: date,
                    repositoryIdentity: identity,
                    commitHash: hash,
                    authorEmail: email,
                    authorName: name
                )
            }
    }

    static func matching(_ identity: BriefAuthorIdentity,
                         in activities: [CommitActivity]) -> [CommitActivity] {
        guard identity.isUsable else { return [] }
        return activities.filter {
            identity.matches(authorEmail: $0.authorEmail, authorName: $0.authorName)
        }
    }

    static func occurring(_ activities: [CommitActivity],
                          in interval: DateInterval) -> [CommitActivity] {
        activities.filter { activity in
            activity.committedAt >= interval.start && activity.committedAt < interval.end
        }
    }

    /// Keeps the first occurrence of each canonical repository + commit hash.
    static func deduplicated(_ activities: [CommitActivity]) -> [CommitActivity] {
        var seen = Set<String>()
        var unique: [CommitActivity] = []
        for activity in activities {
            guard seen.insert(activity.attributionKey).inserted else { continue }
            unique.append(activity)
        }
        return unique
    }

    // MARK: - Workday selection

    /// The most recent calendar day (strictly before `day`) holding at least
    /// one attributed activity. Weekends, holidays, and vacation days without
    /// commits are skipped automatically; a weekend with commits counts as a
    /// worked day.
    static func mostRecentActiveDay(of activities: [CommitActivity],
                                    before day: Date,
                                    calendar: Calendar) -> Date? {
        let dayStart = calendar.startOfDay(for: day)
        var latest: Date?
        for activity in activities {
            let activityDay = calendar.startOfDay(for: activity.committedAt)
            guard activityDay < dayStart else { continue }
            if latest == nil || activityDay > latest! {
                latest = activityDay
            }
        }
        return latest
    }

    /// Last non-weekend day strictly before `day`. Fallback when the
    /// lookback window holds no attributed commits at all.
    static func previousWeekday(before day: Date, calendar: Calendar) -> Date {
        var candidate = calendar.startOfDay(for: day)
        repeat {
            candidate = calendar.date(byAdding: .day, value: -1, to: candidate) ?? candidate
        } while calendar.isDateInWeekend(candidate)
        return candidate
    }

    /// Half-open interval `[startOfReportedDay, startOfNextDay)` covering the
    /// single reported workday.
    static func workdayInterval(for day: Date, calendar: Calendar) -> DateInterval {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return DateInterval(start: start, end: end)
    }

    // MARK: - Composition

    /// Builds the deterministic local brief for `day`. Lines come from the
    /// collected commit activity; the brief is a record of completed work.
    static func compose(
        day: Date,
        activities: [CommitActivity],
        now: Date = Date(),
        activityRange: DateInterval? = nil,
        sourceRepositoryNames: [String] = []
    ) -> MorningBrief {
        let lines = activities.isEmpty
            ? [Self.quietDayLine]
            : yesterdayLines(from: activities)
        return MorningBrief(
            day: day,
            yesterdayLines: lines,
            generatedAt: now,
            source: .local,
            activityRangeStart: activityRange?.start,
            activityRangeEnd: activityRange?.end,
            sourceRepositoryNames: Self.uniqueNames(sourceRepositoryNames)
        )
    }

    /// Terse "Repo — subject" lines, most recent first, clamped to the
    /// report limit. Identical commits (same repository identity + hash)
    /// appear once; same-basename independent repositories stay distinct.
    static func yesterdayLines(from activities: [CommitActivity]) -> [String] {
        var seen = Set<String>()
        var lines: [String] = []
        for activity in activities.sorted(by: { $0.committedAt > $1.committedAt }) {
            guard seen.insert(activity.attributionKey).inserted else { continue }
            lines.append(reportLine(for: activity))
            if lines.count == MorningBrief.maxYesterdayLines { break }
        }
        return lines
    }

    static func reportLine(for activity: CommitActivity) -> String {
        let budget = max(0, maxLineLength - activity.repositoryName.count - lineSeparator.count)
        return activity.repositoryName + lineSeparator + truncate(activity.subject, maxLength: budget)
    }

    static func truncate(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        let clipped = String(text.prefix(max(0, maxLength - 1)))
        return clipped.trimmingCharacters(in: .whitespaces) + "…"
    }

    static let quietDayLine = "Quiet day — no commits recorded."

    static func uniqueNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for name in names where !name.isEmpty {
            guard seen.insert(name).inserted else { continue }
            ordered.append(name)
        }
        return ordered
    }

    private static func parseISODate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: trimmed) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: trimmed)
    }
}
