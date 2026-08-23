import Foundation

/// One activity item collected from a workspace repository.
struct CommitActivity: Equatable, Sendable {
    let repositoryName: String
    let subject: String
    let committedAt: Date
}

/// Pure composition of `MorningBrief` content from collected activity.
/// No I/O; unit-testable with synthetic data only.
enum BriefComposer {
    static let lineSeparator = " — "
    static let maxLineLength = 72

    // MARK: - Git log parsing

    static let gitLogFormat = "%cI%x09%s"

    /// Parses `git log --pretty=format:%cI%x09%s` output into activities.
    /// Never runs git itself.
    static func parseGitLogOutput(_ output: String, repositoryName: String) -> [CommitActivity] {
        let formatter = ISO8601DateFormatter()
        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> CommitActivity? in
                let parts = line.split(
                    separator: "\t",
                    maxSplits: 1,
                    omittingEmptySubsequences: false
                )
                guard parts.count == 2 else { return nil }
                guard let date = formatter.date(from: String(parts[0])) else { return nil }
                let subject = String(parts[1]).trimmingCharacters(in: .whitespaces)
                guard !subject.isEmpty else { return nil }
                return CommitActivity(repositoryName: repositoryName,
                                      subject: subject,
                                      committedAt: date)
            }
    }

    // MARK: - Composition

    /// Builds the deterministic local brief for `day`. Yesterday lines come
    /// from commit activity; today tasks carry forward from the most recent
    /// earlier brief so the user keeps their plan across days.
    static func compose(day: Date,
                        activities: [CommitActivity],
                        carriedTasks: [String],
                        now: Date = Date()) -> MorningBrief {
        let lines = activities.isEmpty
            ? [Self.quietDayLine]
            : yesterdayLines(from: activities)
        let tasks = Array(carriedTasks.prefix(MorningBrief.maxTodayTasks))
        return MorningBrief(
            day: day,
            yesterdayLines: lines,
            todayTasks: tasks,
            generatedAt: now,
            source: .local,
            tasksManuallyEdited: false
        )
    }

    /// Terse "Repo — subject" lines, most recent first, deduplicated,
    /// clamped to the report limit.
    static func yesterdayLines(from activities: [CommitActivity]) -> [String] {
        var seen = Set<String>()
        var lines: [String] = []
        for activity in activities.sorted(by: { $0.committedAt > $1.committedAt }) {
            let line = reportLine(for: activity)
            guard seen.insert(line).inserted else { continue }
            lines.append(line)
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
}
