import XCTest
@testable import Console

final class BriefComposerTests: XCTestCase {

    private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private func date(_ string: String) -> Date {
        dayFormatter.date(from: string)!
    }

    // MARK: - Git log parsing

    func testParseGitLogOutputParsesSubjectsAndDates() {
        let output = """
        2026-08-22T09:15:00-07:00\tAdd Go-menu session hotkeys
        2026-08-22T14:40:00-07:00\tFix drawer resize flicker

        """
        let activities = BriefComposer.parseGitLogOutput(output, repositoryName: "Console")

        XCTAssertEqual(activities.count, 2)
        XCTAssertEqual(activities[0].repositoryName, "Console")
        XCTAssertEqual(activities[0].subject, "Add Go-menu session hotkeys")
        XCTAssertEqual(activities[0].committedAt, date("2026-08-22T09:15:00-0700"))
        XCTAssertEqual(activities[1].subject, "Fix drawer resize flicker")
    }

    func testParseGitLogOutputSkipsMalformedLines() {
        let output = """
        not-a-date\tGhost commit
        2026-08-22T09:15:00-07:00
        2026-08-22T10:00:00-07:00\t

        """
        let activities = BriefComposer.parseGitLogOutput(output, repositoryName: "Repo")
        XCTAssertTrue(activities.isEmpty)
    }

    func testParseGitLogOutputKeepsTabsInsideSubjects() {
        let output = "2026-08-22T09:15:00-07:00\tSubject with\tan embedded tab\n"
        let activities = BriefComposer.parseGitLogOutput(output, repositoryName: "Repo")
        XCTAssertEqual(activities.count, 1)
        XCTAssertEqual(activities[0].subject, "Subject with\tan embedded tab")
    }

    // MARK: - Report lines

    func testYesterdayLinesOrdersByRecencyAndClampsToThree() {
        let activities = [
            CommitActivity(repositoryName: "Alpha", subject: "Oldest", committedAt: date("2026-08-21T08:00:00+0000")),
            CommitActivity(repositoryName: "Beta", subject: "Newest", committedAt: date("2026-08-21T18:00:00+0000")),
            CommitActivity(repositoryName: "Gamma", subject: "Middle", committedAt: date("2026-08-21T12:00:00+0000")),
            CommitActivity(repositoryName: "Delta", subject: "Too many", committedAt: date("2026-08-21T13:00:00+0000"))
        ]

        let lines = BriefComposer.yesterdayLines(from: activities)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "Beta — Newest")
        XCTAssertEqual(lines[1], "Delta — Too many")
        XCTAssertEqual(lines[2], "Gamma — Middle")
    }

    func testYesterdayLinesDeduplicatesIdenticalLines() {
        let activities = [
            CommitActivity(repositoryName: "Alpha", subject: "Same", committedAt: date("2026-08-21T08:00:00+0000")),
            CommitActivity(repositoryName: "Alpha", subject: "Same", committedAt: date("2026-08-21T09:00:00+0000"))
        ]
        let lines = BriefComposer.yesterdayLines(from: activities)
        XCTAssertEqual(lines, ["Alpha — Same"])
    }

    func testReportLineTruncatesLongSubjects() {
        let longSubject = String(repeating: "word ", count: 30).trimmingCharacters(in: .whitespaces)
        let line = BriefComposer.reportLine(for: CommitActivity(
            repositoryName: "Repository",
            subject: longSubject,
            committedAt: Date()
        ))
        XCTAssertLessThanOrEqual(line.count, BriefComposer.maxLineLength)
        XCTAssertTrue(line.hasSuffix("…"))
        XCTAssertTrue(line.hasPrefix("Repository — "))
    }

    // MARK: - Composition

    func testComposeUsesQuietDayLineWithoutActivities() {
        let brief = BriefComposer.compose(day: Date(), activities: [], carriedTasks: ["Ship it"])
        XCTAssertEqual(brief.yesterdayLines, [BriefComposer.quietDayLine])
        XCTAssertEqual(brief.source, .local)
        XCTAssertFalse(brief.tasksManuallyEdited)
    }

    func testComposeCarriesTasksForwardClampedToLimit() {
        let activities = [
            CommitActivity(repositoryName: "Alpha", subject: "Did a thing", committedAt: Date())
        ]
        let carried = ["Task one", "Task two", "Overflowing task"]
        let brief = BriefComposer.compose(day: Date(), activities: activities, carriedTasks: carried)

        XCTAssertEqual(brief.todayTasks, ["Task one", "Task two"])
        XCTAssertEqual(brief.yesterdayLines, ["Alpha — Did a thing"])
    }

    func testReportLinesProduceFiveLineExecReport() {
        let activities = [
            CommitActivity(repositoryName: "Alpha", subject: "One", committedAt: Date()),
            CommitActivity(repositoryName: "Beta", subject: "Two", committedAt: Date()),
            CommitActivity(repositoryName: "Gamma", subject: "Three", committedAt: Date()),
            CommitActivity(repositoryName: "Delta", subject: "Four", committedAt: Date())
        ]
        var brief = BriefComposer.compose(
            day: Date(),
            activities: activities,
            carriedTasks: ["Top task", "Second task"]
        )

        XCTAssertEqual(brief.reportLines.count, MorningBrief.maxYesterdayLines + MorningBrief.maxTodayTasks)
        XCTAssertEqual(brief.reportLines.last, "Second task")

        brief.tasksManuallyEdited = true
        XCTAssertEqual(brief.reportText.split(separator: "\n").count, 5)
    }
}
