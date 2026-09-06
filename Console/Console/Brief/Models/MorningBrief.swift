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
    /// Inclusive start of the authored-date range that produced yesterday's lines.
    var activityRangeStart: Date?
    /// Exclusive end of that authored-date range.
    var activityRangeEnd: Date?
    /// Display names of repositories that were scanned for this report.
    var sourceRepositoryNames: [String]

    var id: Date { day }

    static let maxYesterdayLines = 3
    static let maxTodayTasks = 2

    init(
        day: Date,
        yesterdayLines: [String],
        todayTasks: [String],
        generatedAt: Date,
        source: MorningBriefSource,
        tasksManuallyEdited: Bool,
        activityRangeStart: Date? = nil,
        activityRangeEnd: Date? = nil,
        sourceRepositoryNames: [String] = []
    ) {
        self.day = day
        self.yesterdayLines = yesterdayLines
        self.todayTasks = todayTasks
        self.generatedAt = generatedAt
        self.source = source
        self.tasksManuallyEdited = tasksManuallyEdited
        self.activityRangeStart = activityRangeStart
        self.activityRangeEnd = activityRangeEnd
        self.sourceRepositoryNames = sourceRepositoryNames
    }

    var activityInterval: DateInterval? {
        guard let start = activityRangeStart, let end = activityRangeEnd, end > start else {
            return nil
        }
        return DateInterval(start: start, end: end)
    }

    func activityRangeDescription(calendar: Calendar = .current,
                                  locale: Locale = .current) -> String {
        guard let interval = activityInterval else { return "" }
        return BriefDateRangeSelection.description(
            of: interval,
            calendar: calendar,
            locale: locale
        )
    }

    /// The five (or fewer) report lines, ready to read or paste.
    var reportLines: [String] {
        Array(yesterdayLines.prefix(Self.maxYesterdayLines))
            + Array(todayTasks.prefix(Self.maxTodayTasks))
    }

    /// Plain-text rendering for the copy button.
    var reportText: String {
        reportLines.joined(separator: "\n")
    }

    enum CodingKeys: String, CodingKey {
        case day, yesterdayLines, todayTasks, generatedAt, source, tasksManuallyEdited
        case activityRangeStart, activityRangeEnd, sourceRepositoryNames
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        day = try container.decode(Date.self, forKey: .day)
        yesterdayLines = try container.decode([String].self, forKey: .yesterdayLines)
        todayTasks = try container.decode([String].self, forKey: .todayTasks)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        source = try container.decode(MorningBriefSource.self, forKey: .source)
        tasksManuallyEdited = try container.decode(Bool.self, forKey: .tasksManuallyEdited)
        activityRangeStart = try container.decodeIfPresent(Date.self, forKey: .activityRangeStart)
        activityRangeEnd = try container.decodeIfPresent(Date.self, forKey: .activityRangeEnd)
        sourceRepositoryNames = try container.decodeIfPresent([String].self, forKey: .sourceRepositoryNames) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(day, forKey: .day)
        try container.encode(yesterdayLines, forKey: .yesterdayLines)
        try container.encode(todayTasks, forKey: .todayTasks)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(source, forKey: .source)
        try container.encode(tasksManuallyEdited, forKey: .tasksManuallyEdited)
        try container.encodeIfPresent(activityRangeStart, forKey: .activityRangeStart)
        try container.encodeIfPresent(activityRangeEnd, forKey: .activityRangeEnd)
        try container.encode(sourceRepositoryNames, forKey: .sourceRepositoryNames)
    }
}
