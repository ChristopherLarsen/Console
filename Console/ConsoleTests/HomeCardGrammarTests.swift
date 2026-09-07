import XCTest
@testable import Console

/// The shared attention-channel mapping (Design/HomeCards/DESIGN_PROMPT.md §3)
/// and the compact relative-age formatter (§5). Pure logic, no views.
@MainActor
final class HomeCardGrammarTests: XCTestCase {

    // MARK: - Ticket status column

    func testTicketStatusChannels() {
        XCTAssertEqual(AttentionChannel.forTicketStatus("Blocked"), .needsYou)
        XCTAssertEqual(AttentionChannel.forTicketStatus("Testing"), .inFlight)
        XCTAssertEqual(AttentionChannel.forTicketStatus("In Review"), .inFlight)
        XCTAssertEqual(AttentionChannel.forTicketStatus("In Progress"), .active)
        XCTAssertEqual(AttentionChannel.forTicketStatus("Done"), .clear)
        XCTAssertEqual(AttentionChannel.forTicketStatus("Backlog"), .parked)
        XCTAssertEqual(AttentionChannel.forTicketStatus("To Do"), .parked)
        // Unfamiliar vocabulary parks in grey rather than guessing.
        XCTAssertEqual(AttentionChannel.forTicketStatus("Some Custom Status"), .parked)
        XCTAssertEqual(AttentionChannel.forTicketStatus(nil), .parked)
    }

    // MARK: - Merge-request condition precedence

    private func mrState(
        draft: Bool = false,
        pipeline: String? = nil,
        review: String? = nil
    ) -> (channel: AttentionChannel, label: String)? {
        AttentionChannel.forMergeRequest(
            isDraft: draft,
            pipelineDisplayState: pipeline,
            reviewDisplayState: review
        )
    }

    func testMergeRequestPrecedence() {
        // failed > blocked > running > draft > passed — by condition rank,
        // not by which side rendered the state.
        XCTAssertEqual(
            mrState(draft: true, pipeline: "Failed")?.channel,
            .needsYou,
            "failed beats draft"
        )
        XCTAssertEqual(
            mrState(pipeline: "Running", review: "Failed")?.channel,
            .needsYou,
            "a human-blocking review outranks a moving pipeline"
        )
        XCTAssertEqual(
            mrState(pipeline: "Running", review: "Changes requested")?.channel,
            .needsYou,
            "changes requested outranks running"
        )
        XCTAssertEqual(
            mrState(pipeline: "Running", review: "Approved")?.channel,
            .inFlight,
            "a settled review does not outrank a moving pipeline"
        )
        XCTAssertEqual(
            mrState(pipeline: "Passed", review: "Changes requested")?.channel,
            .needsYou,
            "changes requested outranks a settled pipeline"
        )
        XCTAssertEqual(mrState(pipeline: "Passed", review: nil)?.channel, .clear)
        XCTAssertEqual(mrState(draft: true, pipeline: "Passed")?.label, "Draft", "draft beats passed")
        XCTAssertEqual(mrState(draft: true, pipeline: nil)?.label, "Draft")
        XCTAssertNil(mrState(), "no rendered conditions means no state text")
    }

    func testReviewApprovalBecomesCardState() {
        XCTAssertEqual(mrState(pipeline: nil, review: "Approved")?.channel, .clear)
        XCTAssertEqual(mrState(pipeline: nil, review: "Approved")?.label, "Approved")
        XCTAssertEqual(mrState(pipeline: "Failed", review: "Approved")?.channel, .needsYou)
    }

    func testMergeRequestLabelsAreVerbatim() {
        XCTAssertEqual(mrState(pipeline: "Failed")?.label, "Failed")
        XCTAssertEqual(mrState(review: "blocked")?.label, "blocked")
    }

    // MARK: - Session channel

    func testSessionChannelsMatchTheSharedTable() {
        let needsYouStates: [DisplayedSessionState] = [
            .needsApproval, .needsInput, .blocked, .needsReview, .error,
        ]
        for state in needsYouStates {
            XCTAssertEqual(state.attentionChannel, .needsYou, "\(state) needs you")
        }
        XCTAssertEqual(DisplayedSessionState.working.attentionChannel, .active)
        XCTAssertEqual(DisplayedSessionState.done.attentionChannel, .clear)
        for state in [DisplayedSessionState.idle, .starting, .exited, .unknown] {
            XCTAssertEqual(state.attentionChannel, .parked, "\(state) is parked")
        }
    }

    // MARK: - Relative age

    func testRelativeStringsParse() {
        let now = Date(timeIntervalSince1970: 1_787_000_000)
        XCTAssertEqual(RelativeAge.compact(from: "38 minutes ago", now: now), "38m")
        XCTAssertEqual(RelativeAge.compact(from: "4 hours ago", now: now), "4h")
        XCTAssertEqual(RelativeAge.compact(from: "2 days ago", now: now), "2d")
        XCTAssertEqual(RelativeAge.compact(from: "just now", now: now), "now")
        XCTAssertEqual(RelativeAge.compact(from: "about an hour ago", now: now), "1h")
        XCTAssertEqual(RelativeAge.compact(from: "updated 4 hours ago", now: now), "4h")
    }

    func testAbsoluteTimestampsParse() {
        let now = RelativeAge.parseAbsoluteForTesting("Aug 21, 2026, 11:34 PM")!
        XCTAssertEqual(RelativeAge.compact(from: "Aug 21, 2026, 11:04 PM", now: now), "30m")
        XCTAssertEqual(RelativeAge.compact(from: "Aug 20, 2026, 11:34 PM", now: now), "1d")
    }

    func testAbbreviatedRelativeStringsParse() {
        let now = Date(timeIntervalSince1970: 1_787_000_000)
        XCTAssertEqual(RelativeAge.compact(from: "2h", now: now), "2h")
        XCTAssertEqual(RelativeAge.compact(from: "1d ago", now: now), "1d")
        XCTAssertEqual(RelativeAge.compact(from: "5m", now: now), "5m")
        XCTAssertEqual(RelativeAge.compact(from: "10min ago", now: now), "10m")
        XCTAssertEqual(RelativeAge.compact(from: "2hrs", now: now), "2h")
        XCTAssertEqual(RelativeAge.compact(from: "3w ago", now: now), "21d")
        XCTAssertEqual(RelativeAge.compact(from: "2mo", now: now), "2mo")
        XCTAssertEqual(RelativeAge.compact(from: "2y", now: now), "2y")
        XCTAssertEqual(RelativeAge.compact(from: "30s", now: now), "now")
        XCTAssertEqual(RelativeAge.compact(from: "updated 2h ago", now: now), "2h")
        XCTAssertEqual(RelativeAge.compact(from: "created 1d", now: now), "1d")
    }

    func testJiraAtTimestampsParse() {
        let now = RelativeAge.parseAbsoluteForTesting("Aug 21, 2026 at 11:34 PM")!
        XCTAssertEqual(RelativeAge.compact(from: "Aug 21, 2026 at 11:04 PM", now: now), "30m")
        XCTAssertEqual(RelativeAge.compact(from: "Aug 20, 2026 at 11:34 PM", now: now), "1d")
    }

    func testUnparseableFallsBackVerbatim() {
        XCTAssertEqual(RelativeAge.compact(from: "yesterdayish"), "yesterdayish")
        XCTAssertEqual(RelativeAge.compact(from: ""), nil)
        XCTAssertEqual(RelativeAge.compact(from: nil), nil)
    }

    func testCompactBuckets() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        func age(_ seconds: TimeInterval) -> String {
            RelativeAge.compact(date: now.addingTimeInterval(-seconds), now: now)
        }
        XCTAssertEqual(age(30), "now")
        XCTAssertEqual(age(59 * 60), "59m")
        XCTAssertEqual(age(23 * 3600), "23h")
        XCTAssertEqual(age(5 * 86400), "5d")
        XCTAssertEqual(age(45 * 86400), "45d")
        XCTAssertEqual(age(90 * 86400), "3mo")
        XCTAssertEqual(age(800 * 86400), "2y")
    }
}
