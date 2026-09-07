import XCTest
import SwiftUI
@testable import Console

/// The red attention badge predicates (Design/HomeCards/DESIGN_PROMPT.md §3):
/// which ticket, merge request, or session state demands a human. Pure logic,
/// no views.
@MainActor
final class AttentionBadgeTests: XCTestCase {

    // MARK: - Tickets

    func testTicketBadgeOnHighAndHighestPriority() {
        XCTAssertTrue(AttentionChannel.ticketWantsBadge(priority: "Highest", status: nil))
        XCTAssertTrue(AttentionChannel.ticketWantsBadge(priority: "High", status: "To Do"))
        // Case and whitespace come from the host's rendered text.
        XCTAssertTrue(AttentionChannel.ticketWantsBadge(priority: "  high  ", status: nil))
    }

    func testTicketBadgeOnBlockedStatusRegardlessOfPriority() {
        XCTAssertTrue(AttentionChannel.ticketWantsBadge(priority: nil, status: "Blocked"))
        XCTAssertTrue(AttentionChannel.ticketWantsBadge(priority: "Low", status: "blocked"))
        XCTAssertTrue(AttentionChannel.ticketWantsBadge(priority: "Medium", status: "Blocked"))
    }

    func testTicketBadgeStaysQuietForOrdinaryTickets() {
        XCTAssertFalse(AttentionChannel.ticketWantsBadge(priority: nil, status: nil))
        XCTAssertFalse(AttentionChannel.ticketWantsBadge(priority: "Medium", status: "In Progress"))
        XCTAssertFalse(AttentionChannel.ticketWantsBadge(priority: "Low", status: "To Do"))
        XCTAssertFalse(AttentionChannel.ticketWantsBadge(priority: "Critical", status: nil),
                       "only High/Highest are urgent; unfamiliar vocabulary never guesses")
    }

    // MARK: - Merge requests

    private func mrBadge(
        kind: CodeHostListKind,
        draft: Bool = false,
        pipeline: String? = nil,
        review: String? = nil
    ) -> Bool {
        AttentionChannel.mergeRequestWantsBadge(
            kind: kind,
            isDraft: draft,
            pipelineDisplayState: pipeline,
            reviewDisplayState: review
        )
    }

    func testEveryReviewsRequestedRowWantsTheBadge() {
        XCTAssertTrue(mrBadge(kind: .reviewsRequested))
        XCTAssertTrue(mrBadge(kind: .reviewsRequested, draft: true))
        XCTAssertTrue(mrBadge(kind: .reviewsRequested, pipeline: "Passed"))
        XCTAssertTrue(mrBadge(kind: .reviewsRequested, pipeline: nil, review: nil))
    }

    func testAuthoredRowsBadgeOnlyOnNeedsYouConditions() {
        XCTAssertFalse(mrBadge(kind: .authored), "no rendered condition, no badge")
        XCTAssertFalse(mrBadge(kind: .authored, draft: true), "draft parks")
        XCTAssertFalse(mrBadge(kind: .authored, pipeline: "Passed"), "passed is clear")
        XCTAssertFalse(mrBadge(kind: .authored, pipeline: "Running"), "running is in flight, not blocking")
        XCTAssertTrue(mrBadge(kind: .authored, pipeline: "Failed"), "failed pipeline blocks")
        XCTAssertTrue(mrBadge(kind: .authored, review: "Blocked"))
    }

    func testChangesRequestedReadsAsNeedsYou() {
        let state = AttentionChannel.forMergeRequest(
            isDraft: false,
            pipelineDisplayState: nil,
            reviewDisplayState: "Changes requested"
        )
        XCTAssertEqual(state?.channel, .needsYou)
        XCTAssertEqual(state?.label, "Changes requested", "the label stays verbatim")

        XCTAssertTrue(mrBadge(kind: .authored, review: "changes requested"))
        // Changes requested outranks draft: the author still owes work.
        XCTAssertEqual(
            AttentionChannel.forMergeRequest(
                isDraft: true,
                pipelineDisplayState: nil,
                reviewDisplayState: "Changes requested"
            )?.channel,
            .needsYou
        )
    }

    // MARK: - Row-one glyph slot

    /// The 6pt dot and the 12pt badge share one fixed-width leading slot, so
    /// the identity text's x-origin never moves between the two states.
    func testCardGlyphSlotWidthIsFixedAcrossDotAndBadge() {
        for needsYou in [false, true] {
            let glyph = HomeCardGlyph(color: .gray, needsYou: needsYou)
            let host = NSHostingView(rootView: glyph)
            XCTAssertEqual(
                host.fittingSize.width,
                HomeCardMetrics.glyphSlotWidth,
                "Glyph slot width must not depend on needsYou"
            )
        }
    }
}
