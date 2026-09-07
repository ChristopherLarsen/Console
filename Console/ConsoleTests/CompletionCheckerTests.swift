import XCTest
@testable import Console

final class CompletionCheckerTests: XCTestCase {

    private var tempDirectories: [URL] = []

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        executionTimeAllowance = 15
        tempDirectories = []
    }

    override func tearDown() {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    func testFileExistsReturnsTrueWhenPresent() async throws {
        let file = try makeTempFile()
        let passed = try await runThrowingWithTimeout {
            await CompletionChecker().waitForCompletion(.fileExists(file.path), timeout: 1)
        }
        XCTAssertTrue(passed)
    }

    func testFileExistsReturnsFalseAfterTimeout() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("console-review-06-missing-\(UUID().uuidString)")
        let start = Date()
        let passed = try await runThrowingWithTimeout {
            await CompletionChecker().waitForCompletion(.fileExists(missing.path), timeout: 0.25)
        }
        XCTAssertFalse(passed)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testPollingStopsWhenTaskCancelled() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("console-review-06-missing-\(UUID().uuidString)")
        let start = Date()
        let task = Task {
            await CompletionChecker().waitForCompletion(.fileExists(missing.path), timeout: 10)
        }
        try await Task.sleep(nanoseconds: 80_000_000)
        task.cancel()
        let passed = try await runThrowingWithTimeout { await task.value }
        XCTAssertFalse(passed)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testDelayCompletesWithoutCancel() async throws {
        let start = Date()
        let passed = try await runThrowingWithTimeout {
            await CompletionChecker().waitForCompletion(.delay(milliseconds: 120), timeout: 2)
        }
        XCTAssertTrue(passed)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.08)
    }

    func testDelayIsCancellationAware() async throws {
        let start = Date()
        let task = Task {
            await CompletionChecker().waitForCompletion(.delay(milliseconds: 8_000), timeout: 10)
        }
        try await Task.sleep(nanoseconds: 80_000_000)
        task.cancel()
        let passed = try await runThrowingWithTimeout { await task.value }
        XCTAssertFalse(passed)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testInvalidDelayReturnsFalse() async throws {
        let passed = try await runThrowingWithTimeout {
            await CompletionChecker().waitForCompletion(
                CompletionCheck(type: .delay, value: "not-a-number"),
                timeout: 1
            )
        }
        XCTAssertFalse(passed)
    }

    func testCancelledTaskDoesNotWaitForAppRunning() async throws {
        let start = Date()
        let task = Task {
            await CompletionChecker().waitForCompletion(
                .appRunning("com.console.synthetic.missing.\(UUID().uuidString)"),
                timeout: 10
            )
        }
        try await Task.sleep(nanoseconds: 80_000_000)
        task.cancel()
        let passed = try await runThrowingWithTimeout { await task.value }
        XCTAssertFalse(passed)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    // MARK: - Timeout honoring

    func testDelayExceedingTimeoutTimesOutWithoutFalsePass() async throws {
        let start = Date()
        let run = try await runThrowingWithTimeout {
            await CompletionChecker().evaluate(.delay(milliseconds: 2000), timeout: 0.2)
        }
        XCTAssertEqual(run.outcome, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }

    func testZeroTimeoutStillEvaluatesPredicateOnce() async throws {
        let file = try makeTempFile()
        let run = try await runThrowingWithTimeout {
            await CompletionChecker().evaluate(.fileExists(file.path), timeout: 0)
        }
        XCTAssertEqual(run.outcome, .passed)
    }

    func testZeroTimeoutWithMissingPredicateTimesOut() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("console-zero-timeout-missing-\(UUID().uuidString)")
        let run = try await runThrowingWithTimeout {
            await CompletionChecker().evaluate(.fileExists(missing.path), timeout: 0)
        }
        XCTAssertEqual(run.outcome, .timedOut)
    }

    // MARK: - Empty window title

    func testEmptyWindowTitleNeverMatchesAnyWindow() {
        let checker = CompletionChecker()
        XCTAssertFalse(checker.doesWindowExist(withTitle: ""))
        XCTAssertNil(checker.findWindow(withTitle: ""))
    }

    func testEmptyWindowTitleCheckNeverPasses() async throws {
        let run = try await runThrowingWithTimeout {
            await CompletionChecker().evaluate(.windowTitle(""), timeout: 0)
        }
        XCTAssertNotEqual(run.outcome, .passed)
    }

    // MARK: - Helpers

    private func makeTempFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompletionCheckerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let file = directory.appendingPathComponent("present.txt")
        try "synthetic".write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private struct TestTimeout: LocalizedError {
        let seconds: TimeInterval
        var errorDescription: String? { "Test exceeded \(seconds)s hard timeout" }
    }

    private func runThrowingWithTimeout<T: Sendable>(
        seconds: TimeInterval = 8,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TestTimeout(seconds: seconds)
            }
            guard let value = try await group.next() else {
                throw TestTimeout(seconds: seconds)
            }
            group.cancelAll()
            return value
        }
    }
}
