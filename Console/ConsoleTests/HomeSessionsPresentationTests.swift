import XCTest
import SwiftTerm
@testable import Console

/// Presentation rules for the Home Sessions radar: sort by displayed-state
/// priority, "needs you" counting, and subtitle selection. Uses in-memory
/// ConsoleSession values with inert terminal views — no PTYs, no Claude.
@MainActor
final class HomeSessionsPresentationTests: XCTestCase {

    // MARK: - Fixtures

    private var counter = 0

    private func makeSession(
        name: String,
        folder: String? = nil,
        activity: SessionActivity,
        attention: SessionAttention = .none,
        summary: String? = nil,
        artifacts: [SessionArtifact] = []
    ) -> ConsoleSession {
        counter += 1
        return ConsoleSession(
            id: UUID(),
            claudeSessionID: UUID(),
            name: name,
            workingDirectory: URL(fileURLWithPath: "/tmp/\(folder ?? name)"),
            terminalView: ConsoleTerminalView(),
            activity: activity,
            attention: attention,
            summary: summary,
            artifacts: artifacts,
            bridgeStatus: .unknown
        )
    }

    private func state(_ session: ConsoleSession) -> DisplayedSessionState {
        displayedSessionState(activity: session.activity, attention: session.attention)
    }

    // MARK: - Sorting

    func testSortFollowsPriorityRankApprovalBeforeWorkingBeforeExited() {
        let exited = makeSession(name: "Exited", activity: .exited)
        let approval = makeSession(name: "Waiting", activity: .working, attention: .permission)
        let working = makeSession(name: "Busy", activity: .working)

        let sorted = HomeSessionsPresentation.sorted([exited, approval, working])

        XCTAssertEqual(sorted.map(\.name), ["Waiting", "Busy", "Exited"])
    }

    func testSortCoversFullDisplayedStateOrder() {
        let starting = makeSession(name: "Starting", activity: .starting)
        let idle = makeSession(name: "Idle", activity: .idle)
        let error = makeSession(name: "Error", activity: .error)
        let done = makeSession(name: "Done", activity: .idle, attention: .unreadCompletion)
        let blocked = makeSession(name: "Blocked", activity: .working, attention: .blocked)
        let needsInput = makeSession(name: "Question", activity: .idle, attention: .question)
        let unknown = makeSession(name: "Unknown", activity: .unknown)
        let review = makeSession(name: "Review", activity: .working, attention: .needsReview)

        let sorted = HomeSessionsPresentation.sorted([
            starting, unknown, idle, review, done, blocked, needsInput, error,
        ])

        // Store order: starting(0) unknown(1) idle(2) review(3) done(4)
        // blocked(5) needsInput(6) error(7). Equal ranks keep store order,
        // so Review precedes Blocked (both rank 1).
        XCTAssertEqual(sorted.map(\.name), [
            "Question",   // rank 0
            "Review",     // rank 1, store position 3
            "Blocked",    // rank 1, store position 5
            "Error",      // rank 2
            "Done",       // rank 3
            "Idle",       // rank 5
            "Starting",   // rank 6
            "Unknown",    // rank 8
        ])
    }

    func testSortKeepsStoreOrderAsStableTieBreak() {
        let workingLate = makeSession(name: "Working Late", activity: .working)
        let exitedEarly = makeSession(name: "Exited Early", activity: .exited)
        let workingEarly = makeSession(name: "Working Early", activity: .working)
        let exitedLate = makeSession(name: "Exited Late", activity: .exited)

        let sorted = HomeSessionsPresentation.sorted([
            workingLate, exitedEarly, workingEarly, exitedLate,
        ])

        // Ranks group together; within each rank store order is preserved.
        XCTAssertEqual(sorted.map(\.name), [
            "Working Late", "Working Early", "Exited Early", "Exited Late",
        ])
    }

    func testSortDoesNotReorderAlphabetically() {
        let zebra = makeSession(name: "Zebra", activity: .working)
        let alpha = makeSession(name: "Alpha", activity: .working)

        XCTAssertEqual(HomeSessionsPresentation.sorted([zebra, alpha]).map(\.name), [
            "Zebra", "Alpha",
        ])
    }

    func testEmptyArraySortsToEmpty() {
        XCTAssertTrue(HomeSessionsPresentation.sorted([]).isEmpty)
    }

    // MARK: - Needs-you count

    func testNeedsYouCountsBlockingStatesOnly() {
        let sessions = [
            makeSession(name: "A", activity: .working, attention: .permission), // needsApproval
            makeSession(name: "B", activity: .idle, attention: .question),      // needsInput
            makeSession(name: "C", activity: .working, attention: .blocked),    // blocked
            makeSession(name: "D", activity: .working, attention: .needsReview),
            makeSession(name: "E", activity: .error),
        ]

        XCTAssertEqual(HomeSessionsPresentation.needsYouCount(in: sessions), 5)
    }

    func testNeedsYouExcludesNonBlockingStates() {
        let sessions = [
            makeSession(name: "Done", activity: .idle, attention: .unreadCompletion),
            makeSession(name: "Working", activity: .working),
            makeSession(name: "Idle", activity: .idle),
            makeSession(name: "Starting", activity: .starting),
            makeSession(name: "Exited", activity: .exited),
            makeSession(name: "Unknown", activity: .unknown),
        ]

        XCTAssertEqual(HomeSessionsPresentation.needsYouCount(in: sessions), 0)
        for session in sessions {
            XCTAssertFalse(
                HomeSessionsPresentation.needsYou(state(session)),
                "\(session.name) must not count as needs-you"
            )
        }
    }

    func testNeedsYouMatchesPerStateTruthTable() {
        let blocking: [DisplayedSessionState] = [
            .needsApproval, .needsInput, .blocked, .needsReview, .error,
        ]
        let notBlocking: [DisplayedSessionState] = [
            .done, .working, .idle, .starting, .exited, .unknown,
        ]

        for value in blocking {
            XCTAssertTrue(HomeSessionsPresentation.needsYou(value), "\(value) should need you")
        }
        for value in notBlocking {
            XCTAssertFalse(HomeSessionsPresentation.needsYou(value), "\(value) should not need you")
        }
    }

    func testEmptyArrayNeedsYouCountIsZero() {
        XCTAssertEqual(HomeSessionsPresentation.needsYouCount(in: []), 0)
    }

    // MARK: - Subtitle

    func testSubtitlePrefersSummary() {
        let session = makeSession(
            name: "AntivirusGodot",
            folder: "AntivirusGodot",
            activity: .working,
            summary: "Asking to run git push to origin"
        )

        XCTAssertEqual(
            HomeSessionsPresentation.subtitle(for: session),
            "Asking to run git push to origin"
        )
    }

    func testSubtitleFallsBackToDistinctFolderBasename() {
        let session = makeSession(name: "Folder 2", folder: "Folder", activity: .working)

        XCTAssertEqual(HomeSessionsPresentation.subtitle(for: session), "Folder")
    }

    func testSubtitleOmittedWhenFolderMatchesNameAndNoSummary() {
        let session = makeSession(name: "Pufferfishh", folder: "Pufferfishh", activity: .working)

        XCTAssertNil(HomeSessionsPresentation.subtitle(for: session))
    }

    func testSubtitleSummaryBeatsDifferentFolder() {
        let session = makeSession(
            name: "Name",
            folder: "OtherFolder",
            activity: .working,
            summary: "Summary wins"
        )

        XCTAssertEqual(HomeSessionsPresentation.subtitle(for: session), "Summary wins")
    }

    func testSubtitleIgnoresEmptySummary() {
        let session = makeSession(name: "Repo", folder: "Repo", activity: .working, summary: "")

        XCTAssertNil(HomeSessionsPresentation.subtitle(for: session))
    }

    // MARK: - Artifact chips

    func testArtifactChipsCapAtTwoWithOverflowCount() {
        let session = makeSession(
            name: "Preview Alpha",
            activity: .working,
            artifacts: [
                SessionArtifact(kind: .jiraIssue, label: "ENG-101"),
                SessionArtifact(kind: .gitlabMergeRequest, label: "MR !42"),
                SessionArtifact(kind: .jiraIssue, label: "ENG-202"),
            ]
        )

        let presentation = HomeSessionsPresentation.artifactChips(for: session)

        // Latest two, matching SessionInfoStrip; older chips count as overflow.
        XCTAssertEqual(presentation.chips.map(\.label), ["MR !42", "ENG-202"])
        XCTAssertEqual(presentation.overflow, 1)
    }

    func testArtifactChipsWithoutArtifactsShowNothing() {
        let session = makeSession(name: "Plain", activity: .idle)

        let presentation = HomeSessionsPresentation.artifactChips(for: session)

        XCTAssertTrue(presentation.chips.isEmpty)
        XCTAssertEqual(presentation.overflow, 0)
    }
}
