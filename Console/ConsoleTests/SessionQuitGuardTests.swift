import XCTest
@testable import Console

@MainActor
final class SessionQuitGuardTests: XCTestCase {

    // MARK: - Fixtures

    private func makeTerminalView() -> ConsoleTerminalView {
        let view = ConsoleTerminalView()
        view.configureAppearance()
        return view
    }

    private func makeSession(activity: SessionActivity) -> ConsoleSession {
        ConsoleSession(
            id: UUID(),
            claudeSessionID: UUID(),
            name: "Session \(UUID().uuidString.prefix(6))",
            workingDirectory: URL(fileURLWithPath: NSHomeDirectory()),
            terminalView: makeTerminalView(),
            activity: activity,
            attention: .none,
            summary: nil,
            artifacts: [],
            bridgeStatus: .unknown
        )
    }

    // MARK: - liveSessions filtering

    func testLiveSessionsIncludesEveryActivityExceptExited() {
        let sessions = [
            makeSession(activity: .starting),
            makeSession(activity: .idle),
            makeSession(activity: .working),
            makeSession(activity: .error),
            makeSession(activity: .unknown),
            makeSession(activity: .exited),
        ]

        let live = SessionQuitGuard.liveSessions(from: sessions)

        XCTAssertEqual(live.count, 5)
        XCTAssertFalse(live.contains { $0.activity == .exited })
    }

    func testLiveSessionsOfEmptyStoreIsEmpty() {
        XCTAssertTrue(SessionQuitGuard.liveSessions(from: []).isEmpty)
    }

    // MARK: - Termination decision

    func testTerminateWithNoSessionsSkipsConfirmation() {
        let guard_ = SessionQuitGuard()
        guard_.sessionsProvider = { [] }
        var prompted = false
        guard_.presentConfirmation = { _ in
            prompted = true
            return false
        }

        let reply = guard_.applicationShouldTerminate(NSApplication.shared)

        XCTAssertEqual(reply, .terminateNow)
        XCTAssertFalse(prompted)
    }

    func testTerminateWithExitedOnlySessionsSkipsConfirmation() {
        let guard_ = SessionQuitGuard()
        guard_.sessionsProvider = {
            [self.makeSession(activity: .exited), self.makeSession(activity: .exited)]
        }
        var prompted = false
        guard_.presentConfirmation = { _ in
            prompted = true
            return false
        }

        let reply = guard_.applicationShouldTerminate(NSApplication.shared)

        XCTAssertEqual(reply, .terminateNow)
        XCTAssertFalse(prompted)
    }

    func testConfirmedQuitTerminatesWhenLiveSessionsExist() {
        let guard_ = SessionQuitGuard()
        guard_.sessionsProvider = {
            [self.makeSession(activity: .idle), self.makeSession(activity: .exited)]
        }
        var promptedCount: Int?
        guard_.presentConfirmation = { liveCount in
            promptedCount = liveCount
            return true
        }

        let reply = guard_.applicationShouldTerminate(NSApplication.shared)

        XCTAssertEqual(reply, .terminateNow)
        XCTAssertEqual(promptedCount, 1)
    }

    func testCancelledConfirmationBlocksTermination() {
        let guard_ = SessionQuitGuard()
        guard_.sessionsProvider = {
            [self.makeSession(activity: .working), self.makeSession(activity: .starting)]
        }
        var promptedCount = 0
        guard_.presentConfirmation = { liveCount in
            promptedCount = liveCount
            return false
        }

        let reply = guard_.applicationShouldTerminate(NSApplication.shared)

        XCTAssertEqual(reply, .terminateCancel)
        XCTAssertEqual(promptedCount, 2)
    }

    func testSuppressedGuardTerminatesWithoutPrompting() {
        let guard_ = SessionQuitGuard()
        guard_.isSuppressed = true
        guard_.sessionsProvider = { [self.makeSession(activity: .working)] }
        var prompted = false
        guard_.presentConfirmation = { _ in
            prompted = true
            return true
        }

        let reply = guard_.applicationShouldTerminate(NSApplication.shared)

        XCTAssertEqual(reply, .terminateNow)
        XCTAssertFalse(prompted)
    }
}
