import XCTest
@testable import Console

final class HeadlessProcessExitTests: XCTestCase {
    func testAlreadyExitedChildCompletesWithoutWaitingForDeadline() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()

        let completed = expectation(description: "Already-exited child is observed")
        Task {
            let exit = await HeadlessProcessTransport.awaitExit(process, deadline: Date().addingTimeInterval(30))
            XCTAssertEqual(exit, .exited(0))
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 2)
    }

    func testRunningChildIsTerminatedAtDeadline() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()

        let exit = await HeadlessProcessTransport.awaitExit(process, deadline: Date().addingTimeInterval(0.1))
        XCTAssertEqual(exit, .timedOut)
        XCTAssertFalse(process.isRunning)
    }
}
