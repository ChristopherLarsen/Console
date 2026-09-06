import XCTest
@testable import Console

final class ProcessRunnerTests: XCTestCase {

    private let megabytePlusBytes = 1_310_720
    private let ddBlockCount = "1280"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        executionTimeAllowance = 30
    }

    func testStdoutLargerThanOneMegabyteCompletes() async throws {
        let count = ddBlockCount
        let result = try await runWithTimeout {
            try await SystemProcessRunner().run(
                executablePath: "/bin/dd",
                arguments: ["if=/dev/zero", "bs=1024", "count=\(count)", "of=/dev/stdout"],
                workingDirectory: nil
            )
        }

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertGreaterThanOrEqual(result.standardOutputByteCount, megabytePlusBytes)
        XCTAssertTrue(result.standardOutputTruncated)
        XCTAssertEqual(result.standardOutput.utf8.count, SystemProcessRunner.defaultMaxOutputBytesPerStream)
        XCTAssertFalse(result.standardErrorTruncated)
    }

    func testStderrLargerThanOneMegabyteCompletes() async throws {
        let count = ddBlockCount
        let result = try await runWithTimeout {
            try await SystemProcessRunner().run(
                executablePath: "/bin/dd",
                arguments: ["if=/dev/zero", "bs=1024", "count=\(count)", "of=/dev/stderr"],
                workingDirectory: nil
            )
        }

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertGreaterThanOrEqual(result.standardErrorByteCount, megabytePlusBytes)
        XCTAssertTrue(result.standardErrorTruncated)
        XCTAssertEqual(result.standardError.utf8.count, SystemProcessRunner.defaultMaxOutputBytesPerStream)
        XCTAssertFalse(result.standardOutputTruncated)
    }

    func testStdoutAndStderrLargerThanOneMegabyteCompleteTogether() async throws {
        let script = "dd if=/dev/zero bs=1024 count=\(ddBlockCount) of=/dev/stdout; dd if=/dev/zero bs=1024 count=\(ddBlockCount) of=/dev/stderr"
        let result = try await runWithTimeout {
            try await SystemProcessRunner().run(
                executablePath: "/bin/sh",
                arguments: ["-c", script],
                workingDirectory: nil
            )
        }

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertGreaterThanOrEqual(result.standardOutputByteCount, megabytePlusBytes)
        XCTAssertGreaterThanOrEqual(result.standardErrorByteCount, megabytePlusBytes)
        XCTAssertTrue(result.standardOutputTruncated)
        XCTAssertTrue(result.standardErrorTruncated)
    }

    func testEmptyOutputFinishesOnce() async throws {
        let result = try await runWithTimeout {
            try await SystemProcessRunner().run(
                executablePath: "/usr/bin/true",
                arguments: [],
                workingDirectory: nil
            )
        }

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutputByteCount, 0)
        XCTAssertEqual(result.standardErrorByteCount, 0)
        XCTAssertEqual(result.standardOutput, "")
        XCTAssertEqual(result.standardError, "")
        XCTAssertFalse(result.standardOutputTruncated)
        XCTAssertFalse(result.standardErrorTruncated)
    }

    func testNonexistentExecutableFinishesOnce() async throws {
        let missing = "/tmp/console-review-05-missing-\(UUID().uuidString)"
        var caught: Error?
        do {
            _ = try await runWithTimeout {
                try await SystemProcessRunner().run(
                    executablePath: missing,
                    arguments: [],
                    workingDirectory: nil
                )
            }
        } catch {
            caught = error
        }

        guard let processError = caught as? ProcessRunError else {
            return XCTFail("Expected ProcessRunError, got \(String(describing: caught))")
        }
        XCTAssertEqual(processError, .executableMissing(missing))
    }

    func testFastNonzeroExitFinishesOnce() async throws {
        let result = try await runWithTimeout {
            try await SystemProcessRunner().run(
                executablePath: "/usr/bin/false",
                arguments: [],
                workingDirectory: nil
            )
        }

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(result.standardOutput, "")
        XCTAssertFalse(result.standardOutputTruncated)
        XCTAssertFalse(result.standardErrorTruncated)
    }

    func testTruncationIsReportedBelowDefaultCap() async throws {
        let runner = SystemProcessRunner(maxOutputBytesPerStream: 64)
        let result = try await runWithTimeout {
            try await runner.run(
                executablePath: "/bin/dd",
                arguments: ["if=/dev/zero", "bs=32", "count=8", "of=/dev/stdout"],
                workingDirectory: nil
            )
        }

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutputByteCount, 256)
        XCTAssertTrue(result.standardOutputTruncated)
        XCTAssertEqual(result.standardOutput.utf8.count, 64)
        XCTAssertTrue(result.formattedStandardOutput.contains("truncated"))
        XCTAssertTrue(result.formattedStandardOutput.contains("256 bytes produced"))
    }

    // MARK: - Timeout

    private struct TestTimeout: LocalizedError {
        let seconds: TimeInterval
        var errorDescription: String? { "Test exceeded \(seconds)s hard timeout" }
    }

    private func runWithTimeout(
        seconds: TimeInterval = 10,
        _ work: @escaping @Sendable () async throws -> ProcessResult
    ) async throws -> ProcessResult {
        try await withThrowingTaskGroup(of: ProcessResult.self) { group in
            group.addTask {
                try await work()
            }
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
