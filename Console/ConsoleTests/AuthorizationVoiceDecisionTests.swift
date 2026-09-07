import XCTest
@testable import Console

/// H22-F01 — voice authorization must match whole word tokens, not substrings.
final class AuthorizationVoiceDecisionTests: XCTestCase {

    private let defaults = ["authorized", "proceed", "ok", "go", "sure"]

    func testBareApprovalWordApproves() {
        XCTAssertEqual(
            AuthorizationVoiceDecision.evaluate(forTranscript: "sure", approveWords: defaults),
            .approve
        )
        XCTAssertEqual(
            AuthorizationVoiceDecision.evaluate(forTranscript: "Ok.", approveWords: defaults),
            .approve
        )
        XCTAssertEqual(
            AuthorizationVoiceDecision.evaluate(forTranscript: "authorized please", approveWords: defaults),
            .approve
        )
    }

    func testSubstringUtterancesDoNotApprove() {
        // "ok" inside "okay wait" / "going" must not approve.
        XCTAssertEqual(
            AuthorizationVoiceDecision.evaluate(forTranscript: "okay wait", approveWords: defaults),
            .none
        )
        XCTAssertEqual(
            AuthorizationVoiceDecision.evaluate(forTranscript: "going home now", approveWords: defaults),
            .none
        )
        // The negation path covers "sure" inside "I'm not sure".
        XCTAssertEqual(
            AuthorizationVoiceDecision.evaluate(forTranscript: "I'm not sure", approveWords: defaults),
            .none
        )
        XCTAssertEqual(
            AuthorizationVoiceDecision.evaluate(forTranscript: "no not now", approveWords: defaults),
            .none
        )
    }

    func testNegatedApprovalDoesNotApprove() {
        XCTAssertEqual(
            AuthorizationVoiceDecision.evaluate(forTranscript: "I'm not sure", approveWords: defaults),
            .none
        )
        XCTAssertEqual(
            AuthorizationVoiceDecision.evaluate(forTranscript: "no not now", approveWords: defaults),
            .none
        )
    }

    func testDenyWordsDeny() {
        XCTAssertEqual(
            AuthorizationVoiceDecision.evaluate(forTranscript: "cancel", approveWords: defaults),
            .deny
        )
        XCTAssertEqual(
            AuthorizationVoiceDecision.evaluate(forTranscript: "nevermind", approveWords: defaults),
            .deny
        )
    }

    func testDenyWinsOverApproval() {
        XCTAssertEqual(
            AuthorizationVoiceDecision.evaluate(forTranscript: "I'm not sure, cancel", approveWords: defaults),
            .deny
        )
        XCTAssertEqual(
            AuthorizationVoiceDecision.evaluate(forTranscript: "sure cancel", approveWords: defaults),
            .deny
        )
    }

    func testEmptyTranscriptIsIgnored() {
        XCTAssertEqual(
            AuthorizationVoiceDecision.evaluate(forTranscript: "", approveWords: defaults),
            .none
        )
        XCTAssertEqual(
            AuthorizationVoiceDecision.evaluate(forTranscript: "...", approveWords: defaults),
            .none
        )
    }
}