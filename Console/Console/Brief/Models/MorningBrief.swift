import Foundation

/// How the brief's report lines were produced.
enum MorningBriefSource: String, Codable, Equatable {
    /// Composed deterministically from local commit activity.
    case local
    /// Polished by the configured AI provider at the user's request.
    case ai
}

/// One super-terse executive report for a calendar day: what was done the
/// previous day and the top tasks for today. The whole brief renders as at
/// most `maxYesterdayLines + maxTodayTasks` lines so it can be read aloud
/// at a morning meeting.
struct MorningBrief: Codable, Equatable, Identifiable {
    /// Start-of-day identity for the brief.
    let day: Date
    var yesterdayLines: [String]
    var todayTasks: [String]
    var generatedAt: Date
    var source: MorningBriefSource
    /// Set once the user edits today's tasks by hand; auto-refresh then
    /// never overwrites them.
    var tasksManuallyEdited: Bool

    var id: Date { day }

    static let maxYesterdayLines = 3
    static let maxTodayTasks = 2

    /// The five (or fewer) report lines, ready to read or paste.
    var reportLines: [String] {
        Array(yesterdayLines.prefix(Self.maxYesterdayLines))
            + Array(todayTasks.prefix(Self.maxTodayTasks))
    }

    /// Plain-text rendering for the copy button.
    var reportText: String {
        reportLines.joined(separator: "\n")
    }
}
