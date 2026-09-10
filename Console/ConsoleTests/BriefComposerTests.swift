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

    private func gitLine(
        hash: String,
        email: String,
        name: String,
        isoDate: String,
        subject: String
    ) -> String {
        [hash, email, name, isoDate, subject].joined(separator: "\0")
    }

    private func newYorkCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    // MARK: - Git log parsing

    func testParseGitLogOutputParsesHashAuthorSubjectAndDates() {
        let output = """
        \(gitLine(hash: "aaa111", email: "dev@example.test", name: "Dev", isoDate: "2026-08-22T09:15:00-07:00", subject: "Add Go-menu session hotkeys"))
        \(gitLine(hash: "bbb222", email: "dev@example.test", name: "Dev", isoDate: "2026-08-22T14:40:00-07:00", subject: "Fix drawer resize flicker"))

        """
        let activities = BriefComposer.parseGitLogOutput(
            output,
            repositoryName: "Console",
            repositoryIdentity: "/tmp/console.git"
        )

        XCTAssertEqual(activities.count, 2)
        XCTAssertEqual(activities[0].repositoryName, "Console")
        XCTAssertEqual(activities[0].repositoryIdentity, "/tmp/console.git")
        XCTAssertEqual(activities[0].commitHash, "aaa111")
        XCTAssertEqual(activities[0].authorEmail, "dev@example.test")
        XCTAssertEqual(activities[0].authorName, "Dev")
        XCTAssertEqual(activities[0].subject, "Add Go-menu session hotkeys")
        XCTAssertEqual(activities[0].committedAt, date("2026-08-22T09:15:00-0700"))
        XCTAssertEqual(activities[1].subject, "Fix drawer resize flicker")
    }

    func testParseGitLogOutputSkipsMalformedLines() {
        let output = """
        not-enough-fields
        \(gitLine(hash: "abc", email: "a@b.test", name: "A", isoDate: "not-a-date", subject: "Ghost"))
        \(gitLine(hash: "", email: "a@b.test", name: "A", isoDate: "2026-08-22T10:00:00-07:00", subject: "Empty hash"))
        \(gitLine(hash: "def", email: "a@b.test", name: "A", isoDate: "2026-08-22T10:00:00-07:00", subject: ""))

        """
        let activities = BriefComposer.parseGitLogOutput(output, repositoryName: "Repo")
        XCTAssertTrue(activities.isEmpty)
    }

    func testParseGitLogOutputKeepsTabsInsideSubjects() {
        let output = gitLine(
            hash: "abc",
            email: "dev@example.test",
            name: "Dev",
            isoDate: "2026-08-22T09:15:00-07:00",
            subject: "Subject with\tan embedded tab"
        ) + "\n"
        let activities = BriefComposer.parseGitLogOutput(output, repositoryName: "Repo")
        XCTAssertEqual(activities.count, 1)
        XCTAssertEqual(activities[0].subject, "Subject with\tan embedded tab")
    }

    // MARK: - Attribution filter and dedup

    func testMatchingKeepsOnlySelectedAuthor() {
        let alice = BriefAuthorIdentity(name: "Alice", emails: ["alice@example.test"])
        let activities = [
            CommitActivity(
                repositoryName: "Repo",
                subject: "Alice work",
                committedAt: date("2026-09-04T12:00:00-0400"),
                commitHash: "a1",
                authorEmail: "alice@example.test",
                authorName: "Alice"
            ),
            CommitActivity(
                repositoryName: "Repo",
                subject: "Bob work",
                committedAt: date("2026-09-04T13:00:00-0400"),
                commitHash: "b1",
                authorEmail: "bob@example.test",
                authorName: "Bob"
            )
        ]
        let matched = BriefComposer.matching(alice, in: activities)
        XCTAssertEqual(matched.map(\.subject), ["Alice work"])
    }

    func testMatchingHonorsEmailAliasesAndIgnoresCase() {
        let identity = BriefAuthorIdentity(
            name: "Alice",
            emails: ["alice@example.test", "alice.work@example.test"]
        )
        let activities = [
            CommitActivity(
                repositoryName: "Repo",
                subject: "Personal",
                committedAt: Date(),
                commitHash: "1",
                authorEmail: "Alice@example.test",
                authorName: "Alice"
            ),
            CommitActivity(
                repositoryName: "Repo",
                subject: "Work",
                committedAt: Date(),
                commitHash: "2",
                authorEmail: "alice.work@example.test",
                authorName: "Alice"
            ),
            CommitActivity(
                repositoryName: "Repo",
                subject: "Teammate",
                committedAt: Date(),
                commitHash: "3",
                authorEmail: "bob@example.test",
                authorName: "Bob"
            )
        ]
        let matched = BriefComposer.matching(identity, in: activities)
        XCTAssertEqual(Set(matched.map(\.subject)), ["Personal", "Work"])
    }

    func testDeduplicatedCollapsesLinkedWorktreeHashesAndKeepsIndependentRepos() {
        let shared = "/private/tmp/shared.git"
        let linkedDuplicate = [
            CommitActivity(
                repositoryName: "Main",
                subject: "Shared commit",
                committedAt: date("2026-09-04T12:00:00-0400"),
                repositoryIdentity: shared,
                commitHash: "deadbeef",
                authorEmail: "dev@example.test",
                authorName: "Dev"
            ),
            CommitActivity(
                repositoryName: "Linked",
                subject: "Shared commit",
                committedAt: date("2026-09-04T12:00:00-0400"),
                repositoryIdentity: shared,
                commitHash: "DEADBEEF",
                authorEmail: "dev@example.test",
                authorName: "Dev"
            )
        ]
        XCTAssertEqual(BriefComposer.deduplicated(linkedDuplicate).count, 1)

        let independent = [
            CommitActivity(
                repositoryName: "Console",
                subject: "Same subject",
                committedAt: date("2026-09-04T12:00:00-0400"),
                repositoryIdentity: "/tmp/one/.git",
                commitHash: "aaaa",
                authorEmail: "dev@example.test",
                authorName: "Dev"
            ),
            CommitActivity(
                repositoryName: "Console",
                subject: "Same subject",
                committedAt: date("2026-09-04T12:05:00-0400"),
                repositoryIdentity: "/tmp/two/.git",
                commitHash: "bbbb",
                authorEmail: "dev@example.test",
                authorName: "Dev"
            )
        ]
        XCTAssertEqual(BriefComposer.deduplicated(independent).count, 2)
        XCTAssertEqual(BriefComposer.yesterdayLines(from: independent).count, 2)
    }

    // MARK: - Day boundaries

    func testDayBoundariesRespectSelectedTimeZone() {
        let calendar = newYorkCalendar()
        let day = calendar.startOfDay(for: date("2026-09-05T12:00:00-0400"))
        let interval = DateInterval(
            start: day,
            end: calendar.date(byAdding: .day, value: 1, to: day)!
        )
        let justBefore = CommitActivity(
            repositoryName: "Repo",
            subject: "Thursday late",
            committedAt: date("2026-09-04T23:59:00-0400")
        )
        let start = CommitActivity(
            repositoryName: "Repo",
            subject: "Friday start",
            committedAt: date("2026-09-05T00:00:00-0400")
        )
        let justBeforeEnd = CommitActivity(
            repositoryName: "Repo",
            subject: "Friday late",
            committedAt: date("2026-09-05T23:59:00-0400")
        )
        let nextDay = CommitActivity(
            repositoryName: "Repo",
            subject: "Saturday start",
            committedAt: date("2026-09-06T00:00:00-0400")
        )
        let inRange = BriefComposer.occurring(
            [justBefore, start, justBeforeEnd, nextDay],
            in: interval
        )
        XCTAssertEqual(inRange.map(\.subject), ["Friday start", "Friday late"])
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
        let brief = BriefComposer.compose(day: Date(), activities: [])
        XCTAssertEqual(brief.yesterdayLines, [BriefComposer.quietDayLine])
        XCTAssertEqual(brief.source, .local)
    }

    func testComposeRecordsRangeAndSourceRepositories() {
        let calendar = newYorkCalendar()
        let monday = calendar.startOfDay(for: date("2026-09-07T09:00:00-0400"))
        let interval = DateInterval(
            start: monday,
            end: calendar.date(byAdding: .day, value: 1, to: monday)!
        )
        let brief = BriefComposer.compose(
            day: monday,
            activities: [CommitActivity(repositoryName: "Console", subject: "Work", committedAt: interval.start)],
            activityRange: interval,
            sourceRepositoryNames: ["Console", "Console", "Pufferfishh"]
        )
        XCTAssertEqual(brief.activityRangeStart, interval.start)
        XCTAssertEqual(brief.activityRangeEnd, interval.end)
        XCTAssertEqual(brief.sourceRepositoryNames, ["Console", "Pufferfishh"])
    }

    func testReportLinesAreYesterdayLinesOnly() {
        let activities = [
            CommitActivity(repositoryName: "Alpha", subject: "One", committedAt: date("2026-09-08T09:00:00-0400")),
            CommitActivity(repositoryName: "Beta", subject: "Two", committedAt: date("2026-09-08T10:00:00-0400")),
            CommitActivity(repositoryName: "Gamma", subject: "Three", committedAt: date("2026-09-08T11:00:00-0400")),
            CommitActivity(repositoryName: "Delta", subject: "Four", committedAt: date("2026-09-08T12:00:00-0400"))
        ]
        let brief = BriefComposer.compose(
            day: Date(),
            activities: activities
        )

        XCTAssertEqual(brief.reportLines.count, MorningBrief.maxYesterdayLines)
        XCTAssertEqual(brief.reportLines.first, "Delta — Four")
        XCTAssertEqual(brief.reportLines.last, "Beta — Two")
        XCTAssertEqual(brief.reportText.split(separator: "\n").count, 3)
    }

    // MARK: - Workday selection

    func testMostRecentActiveDayPicksLatestDayWithCommits() {
        let calendar = newYorkCalendar()
        let friday = date("2026-09-04T12:00:00-0400")
        let monday = date("2026-09-07T10:00:00-0400")
        let tuesday = date("2026-09-08T10:00:00-0400")
        let briefDay = date("2026-09-09T09:00:00-0400")

        let activities = [
            CommitActivity(repositoryName: "Alpha", subject: "Friday work", committedAt: friday),
            CommitActivity(repositoryName: "Beta", subject: "Monday work", committedAt: monday),
            CommitActivity(repositoryName: "Gamma", subject: "Tuesday work", committedAt: tuesday)
        ]
        XCTAssertEqual(
            BriefComposer.mostRecentActiveDay(of: activities, before: briefDay, calendar: calendar),
            calendar.startOfDay(for: tuesday)
        )
    }

    func testMostRecentActiveDaySkipsCurrentDayAndReturnsNilWhenQuiet() {
        let calendar = newYorkCalendar()
        let today = date("2026-09-08T10:00:00-0400")
        let yesterday = date("2026-09-07T10:00:00-0400")

        // Commits made today are not "previous workday" candidates.
        let todayOnly = [
            CommitActivity(repositoryName: "Alpha", subject: "Today", committedAt: today)
        ]
        XCTAssertNil(
            BriefComposer.mostRecentActiveDay(of: todayOnly, before: today, calendar: calendar)
        )

        // Past commits become candidates again once the brief moves forward.
        XCTAssertEqual(
            BriefComposer.mostRecentActiveDay(of: todayOnly, before: yesterday, calendar: calendar),
            nil
        )
        XCTAssertNil(
            BriefComposer.mostRecentActiveDay(of: [], before: today, calendar: calendar)
        )
    }

    func testPreviousWeekdaySkipsWeekends() {
        let calendar = newYorkCalendar()
        // Monday 2026-09-07: previous weekday is Friday 2026-09-04.
        let monday = date("2026-09-07T09:00:00-0400")
        XCTAssertEqual(
            BriefComposer.previousWeekday(before: monday, calendar: calendar),
            calendar.startOfDay(for: date("2026-09-04T00:00:00-0400"))
        )
        // Sunday: previous weekday is Friday.
        let sunday = date("2026-09-06T12:00:00-0400")
        XCTAssertEqual(
            BriefComposer.previousWeekday(before: sunday, calendar: calendar),
            calendar.startOfDay(for: date("2026-09-04T00:00:00-0400"))
        )
    }

    func testWorkdayIntervalCoversExactlyOneDay() {
        let calendar = newYorkCalendar()
        let fridayMorning = date("2026-09-04T09:00:00-0400")
        let interval = BriefComposer.workdayInterval(for: fridayMorning, calendar: calendar)
        XCTAssertEqual(interval.start, calendar.startOfDay(for: fridayMorning))
        XCTAssertEqual(
            interval.end,
            calendar.startOfDay(for: date("2026-09-05T00:00:00-0400"))
        )
    }
}
