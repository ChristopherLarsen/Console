import XCTest
@testable import Console

@MainActor
final class SessionWorkspaceLayoutTests: XCTestCase {

    func testClampListWidthHonorsMinMaxAndAvailableWidth() {
        XCTAssertEqual(
            SessionWorkspaceLayout.clampedListWidth(100, availableWidth: 1000),
            SessionWorkspaceLayout.listMinWidth
        )
        XCTAssertEqual(
            SessionWorkspaceLayout.clampedListWidth(260, availableWidth: 1000),
            260
        )
        XCTAssertEqual(
            SessionWorkspaceLayout.clampedListWidth(500, availableWidth: 1000),
            SessionWorkspaceLayout.listMaxWidth
        )

        // 500-point Sessions column: max list is detailMinWidth-constrained.
        XCTAssertEqual(
            SessionWorkspaceLayout.clampedListWidth(260, availableWidth: 500),
            SessionWorkspaceLayout.listMinWidth
        )
        XCTAssertEqual(
            SessionWorkspaceLayout.clampedListWidth(300, availableWidth: 700),
            300
        )
    }

    func testEnterFocusHidesListAndExitRestoresChrome() {
        let layout = SessionWorkspaceLayoutController()
        layout.isListVisible = true
        layout.applyListWidth(300, availableWidth: 1000)

        layout.enterFocusSession(terminalExpanded: true, terminalHeight: 240)
        XCTAssertTrue(layout.isFocusMode)
        XCTAssertTrue(layout.isListVisible)
        XCTAssertFalse(layout.showsSessionList)
        XCTAssertFalse(layout.showsCollapsedListRail)

        let restored = layout.exitFocusSession()
        XCTAssertEqual(restored?.isListVisible, true)
        XCTAssertEqual(restored?.listWidth, 300)
        XCTAssertEqual(restored?.isTerminalExpanded, true)
        XCTAssertEqual(restored?.terminalHeight, 240)
        XCTAssertTrue(layout.showsSessionList)
        XCTAssertFalse(layout.isFocusMode)
    }

    func testExitRestoresIndependentlyCollapsedList() {
        let layout = SessionWorkspaceLayoutController()
        layout.isListVisible = false

        layout.enterFocusSession(terminalExpanded: false, terminalHeight: 150)
        XCTAssertFalse(layout.showsCollapsedListRail)

        let restored = layout.exitFocusSession()
        XCTAssertEqual(restored?.isListVisible, false)
        XCTAssertEqual(restored?.isTerminalExpanded, false)
        XCTAssertEqual(restored?.terminalHeight, 150)
        XCTAssertFalse(layout.showsSessionList)
        XCTAssertTrue(layout.showsCollapsedListRail)
    }

    func testEnterFocusIsIdempotentAndDoesNotCaptureCollapsedDrawer() {
        let layout = SessionWorkspaceLayoutController()
        layout.applyListWidth(220, availableWidth: 1000)

        layout.enterFocusSession(terminalExpanded: true, terminalHeight: 250)
        layout.enterFocusSession(terminalExpanded: false, terminalHeight: 180)

        let restored = layout.exitFocusSession()
        XCTAssertEqual(restored?.isTerminalExpanded, true)
        XCTAssertEqual(restored?.terminalHeight, 250)
        XCTAssertEqual(restored?.listWidth, 220)
        XCTAssertNil(layout.exitFocusSession())
    }

    func testToggleFocusSessionUsesNotedDrawerChrome() {
        let layout = SessionWorkspaceLayoutController()
        layout.noteTerminalChrome(expanded: true, height: 220)
        layout.toggleFocusSession()
        XCTAssertTrue(layout.isFocusMode)
        XCTAssertFalse(layout.showsSessionList)

        layout.toggleFocusSession()
        XCTAssertFalse(layout.isFocusMode)
        XCTAssertEqual(layout.lastRestoredChrome?.isTerminalExpanded, true)
        XCTAssertEqual(layout.lastRestoredChrome?.terminalHeight, 220)
    }

    func testRelayoutGrowsListBackWhenColumnWidens() {
        let layout = SessionWorkspaceLayoutController()
        layout.applyListWidth(260, availableWidth: 500)
        XCTAssertEqual(layout.listWidth, SessionWorkspaceLayout.listMinWidth)
        XCTAssertEqual(layout.preferredListWidth, 260)

        layout.relayout(availableWidth: 1000)
        XCTAssertEqual(layout.listWidth, 260)
    }
}
