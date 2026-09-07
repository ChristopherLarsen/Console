import XCTest
@testable import Console

@MainActor
final class SessionLifecycleReducerTests: XCTestCase {

    // MARK: - Display priority

    private func displayed(_ activity: SessionActivity, _ attention: SessionAttention) -> DisplayedSessionState {
        displayedSessionState(activity: activity, attention: attention)
    }

    func testDisplayPriorityOrder() {
        XCTAssertEqual(displayed(.working, .permission), .needsApproval)
        XCTAssertEqual(displayed(.idle, .question), .needsInput)
        XCTAssertEqual(displayed(.idle, .blocked), .blocked)
        XCTAssertEqual(displayed(.idle, .needsReview), .needsReview)
        XCTAssertEqual(displayed(.error, .none), .error)
        XCTAssertEqual(displayed(.idle, .unreadCompletion), .done)
        XCTAssertEqual(displayed(.working, .none), .working)
        XCTAssertEqual(displayed(.idle, .none), .idle)
        XCTAssertEqual(displayed(.starting, .none), .starting)
        XCTAssertEqual(displayed(.exited, .none), .exited)
        XCTAssertEqual(displayed(.unknown, .none), .unknown)
    }

    func testAttentionOutranksActivityError() {
        XCTAssertTrue(displayed(.idle, .permission) < displayed(.error, .none))
        XCTAssertTrue(displayed(.error, .none) < displayed(.idle, .unreadCompletion))
        XCTAssertTrue(displayed(.working, .none) < displayed(.starting, .none))
    }

    // MARK: - Lifecycle transitions

    private var fresh: SessionLifecycleState { SessionLifecycleState() }

    func testSessionStartMovesToIdleAndKeepsStartingBehind() {
        var state = fresh
        state.apply(.sessionStarted)
        XCTAssertEqual(state.activity, .idle)
        XCTAssertEqual(state.displayedState, .idle)
    }

    func testPromptSubmitSetsWorkingClearsCompletionAndTransientAttention() {
        var state = fresh
        state.apply(.turnCompleted)
        XCTAssertEqual(state.attention, .unreadCompletion)

        state.apply(.promptSubmitted)
        XCTAssertEqual(state.activity, .working)
        XCTAssertEqual(state.attention, .none)
        XCTAssertNil(state.summary)

        state.apply(.permissionRequested)
        XCTAssertEqual(state.attention, .permission)
        state.apply(.promptSubmitted)
        XCTAssertEqual(state.attention, .none)
    }

    func testPermissionRequestDoesNotChangeActivity() {
        var state = fresh
        state.apply(.sessionStarted)
        state.apply(.permissionRequested)
        XCTAssertEqual(state.activity, .idle)
        XCTAssertEqual(state.attention, .permission)
        XCTAssertEqual(state.displayedState, .needsApproval)
    }

    func testQuestionAskedShowsNeedsInput() {
        var state = fresh
        state.apply(.promptSubmitted)
        state.apply(.questionAsked)
        XCTAssertEqual(state.activity, .working)
        XCTAssertEqual(state.displayedState, .needsInput)
    }

    func testTurnCompletedMarksDoneButKeepsHigherAttention() {
        var state = fresh
        state.apply(.sessionStarted)
        state.apply(.turnCompleted)
        XCTAssertEqual(state.activity, .idle)
        XCTAssertEqual(state.attention, .unreadCompletion)
        XCTAssertEqual(state.displayedState, .done)

        state.apply(.permissionRequested)
        state.apply(.turnCompleted)
        XCTAssertEqual(state.attention, .permission, "a pending permission must not be downgraded")
    }

    func testStopFailureSetsError() {
        var state = fresh
        state.apply(.promptSubmitted)
        state.apply(.turnFailed)
        XCTAssertEqual(state.activity, .error)
        XCTAssertEqual(state.displayedState, .error)
    }

    func testCwdChangedOnlyUpdatesDirectory() {
        var state = fresh
        state.apply(.promptSubmitted)
        state.apply(.cwdChanged("/tmp/elsewhere"))
        XCTAssertEqual(state.workingDirectoryPath, "/tmp/elsewhere")
        XCTAssertEqual(state.activity, .working)
    }

    func testSessionEndAndProcessTerminationExit() {
        var state = fresh
        state.apply(.promptSubmitted)
        state.apply(.sessionEnded)
        XCTAssertEqual(state.activity, .exited)

        state = fresh
        state.apply(.promptSubmitted)
        state.apply(.processTerminated)
        XCTAssertEqual(state.activity, .exited)
    }

    func testExitedBeatsHighAttentionInDisplayedState() {
        XCTAssertEqual(displayed(.exited, .permission), .exited)
        XCTAssertEqual(displayed(.exited, .question), .exited)
        XCTAssertEqual(displayed(.exited, .blocked), .exited)
        XCTAssertEqual(displayed(.exited, .needsReview), .exited)
        XCTAssertEqual(displayed(.exited, .unreadCompletion), .exited)
        XCTAssertEqual(displayed(.exited, .none), .exited)
    }

    func testPostExitLifecycleEventsDoNotResurrectActivity() {
        var state = fresh
        state.apply(.promptSubmitted)
        state.apply(.attentionReported(.blocked, message: "needs you"))
        state.apply(.sessionEnded)

        // Async hook reordering: a late prompt/turn/completion must not make
        // the dead row look live.
        state.apply(.turnCompleted)
        state.apply(.promptSubmitted)
        state.apply(.turnFailed)
        state.apply(.attentionReported(.needsReview, message: "late"))
        state.apply(.completionReported(.blocked, summary: "late"))
        state.apply(.cwdChanged("/tmp/late"))

        XCTAssertEqual(state.activity, .exited)
        XCTAssertEqual(state.displayedState, .exited)
        // The last pre-exit summary survives; nothing new is written.
        XCTAssertEqual(state.summary, "needs you")
        XCTAssertNil(state.workingDirectoryPath)
    }

    func testUserInputClearsPermissionAndQuestionOnly() {
        var state = fresh
        state.apply(.permissionRequested)
        state.apply(.userInputObserved)
        XCTAssertEqual(state.attention, .none)

        state.apply(.questionAsked)
        state.apply(.userInputObserved)
        XCTAssertEqual(state.attention, .none)

        state.apply(.attentionReported(.blocked, message: "stuck"))
        state.apply(.userInputObserved)
        XCTAssertEqual(state.attention, .blocked, "reported blocked attention persists")
    }

    // MARK: - Agent messages

    func testAttentionReportStoresMessage() {
        var state = fresh
        state.apply(.attentionReported(.needsReview, message: "Please review diff"))
        XCTAssertEqual(state.attention, .needsReview)
        XCTAssertEqual(state.summary, "Please review diff")
        XCTAssertEqual(state.displayedState, .needsReview)
    }

    func testCompletionReportCompleted() {
        var state = fresh
        state.apply(.sessionStarted)
        state.apply(.completionReported(.completed, summary: "All done"))
        XCTAssertEqual(state.attention, .unreadCompletion)
        XCTAssertEqual(state.summary, "All done")
        XCTAssertEqual(state.displayedState, .done)
    }

    func testCompletionReportBlockedOverridesIdleCompletion() {
        var state = fresh
        state.apply(.completionReported(.blocked, summary: "Waiting on credentials"))
        XCTAssertEqual(state.attention, .blocked)
    }
}
