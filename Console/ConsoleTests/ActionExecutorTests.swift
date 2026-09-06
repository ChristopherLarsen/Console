import XCTest
@testable import Console

final class ActionExecutorTests: XCTestCase {

    private var tempDirectories: [URL] = []
    private let ddBlockCount = "1280"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        executionTimeAllowance = 30
        tempDirectories = []
    }

    override func tearDown() {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
        super.tearDown()
    }

    func testShellStdoutLargerThanOneMegabyteCompletes() async throws {
        let payload = "dd if=/dev/zero bs=1024 count=\(ddBlockCount) of=/dev/stdout"
        let output = try await runWithTimeout {
            try await ActionExecutor().execute(CommandAction(type: .shell, payload: payload, order: 0))
        }

        XCTAssertTrue(output.contains("truncated"), "Expected truncation notice, got \(output.prefix(80))…")
        XCTAssertTrue(output.contains("stdout"))
        XCTAssertGreaterThanOrEqual(output.utf8.count, SystemProcessRunner.defaultMaxOutputBytesPerStream)
    }

    func testShellStderrLargerThanOneMegabyteCompletes() async throws {
        let payload = "dd if=/dev/zero bs=1024 count=\(ddBlockCount) of=/dev/stderr"
        let output = try await runWithTimeout {
            try await ActionExecutor().execute(CommandAction(type: .shell, payload: payload, order: 0))
        }

        XCTAssertFalse(output.isEmpty)
    }

    func testShellStdoutAndStderrLargerThanOneMegabyteCompleteTogether() async throws {
        let script = try makeExecutableScript("""
        #!/bin/sh
        dd if=/dev/zero bs=1024 count=\(ddBlockCount) of=/dev/stdout
        dd if=/dev/zero bs=1024 count=\(ddBlockCount) of=/dev/stderr
        """)

        let payload = script.path
        let output = try await runWithTimeout {
            try await ActionExecutor().execute(CommandAction(type: .shell, payload: payload, order: 0))
        }

        XCTAssertTrue(output.contains("truncated"))
        XCTAssertTrue(output.contains("stdout"))
    }

    func testEmptyShellOutputFinishesOnce() async throws {
        let output = try await runWithTimeout {
            try await ActionExecutor().execute(CommandAction(type: .shell, payload: "true", order: 0))
        }
        XCTAssertEqual(output, "Command executed successfully")
    }

    func testNonexistentShellCommandFinishesOnce() async throws {
        let missing = "console-review-05-missing-\(UUID().uuidString)"
        var caught: Error?
        do {
            _ = try await runWithTimeout {
                try await ActionExecutor().execute(CommandAction(type: .shell, payload: missing, order: 0))
            }
        } catch {
            caught = error
        }

        guard let shellError = caught as? ActionExecutionError,
              case .shellError(let message) = shellError else {
            return XCTFail("Expected shellError, got \(String(describing: caught))")
        }
        XCTAssertFalse(message.isEmpty)
    }

    func testFastNonzeroShellExitFinishesOnce() async throws {
        var caught: Error?
        do {
            _ = try await runWithTimeout {
                try await ActionExecutor().execute(CommandAction(type: .shell, payload: "false", order: 0))
            }
        } catch {
            caught = error
        }

        guard let shellError = caught as? ActionExecutionError,
              case .shellError(let message) = shellError else {
            return XCTFail("Expected shellError, got \(String(describing: caught))")
        }
        XCTAssertTrue(message.contains("Exit code") || !message.isEmpty)
    }

    @MainActor
    func testAppleScriptExecutionLeavesMainActorResponsive() async throws {
        let execution = Task {
            try await ActionExecutor().execute(
                CommandAction(
                    type: .appleScript,
                    payload: "delay 0.6\nreturn \"synthetic-ok\"",
                    order: 0
                )
            )
        }
        let timeout = Task {
            try await Task.sleep(nanoseconds: 10_000_000_000)
            execution.cancel()
            throw TestTimeout(seconds: 10)
        }

        var mainActorTurns = 0
        let deadline = Date().addingTimeInterval(0.35)
        while Date() < deadline {
            mainActorTurns += 1
            await Task.yield()
        }

        let output = try await execution.value
        timeout.cancel()

        XCTAssertGreaterThan(
            mainActorTurns,
            10,
            "Main actor should keep turning while AppleScript is running"
        )
        XCTAssertTrue(output.contains("synthetic-ok"), "Unexpected AppleScript output: \(output)")
    }

    func testEmptyAppleScriptPayloadIsRejectedOnce() async throws {
        var caught: Error?
        do {
            _ = try await runWithTimeout {
                try await ActionExecutor().execute(CommandAction(type: .appleScript, payload: "   ", order: 0))
            }
        } catch {
            caught = error
        }

        guard let executionError = caught as? ActionExecutionError,
              case .invalidPayload = executionError else {
            return XCTFail("Expected invalidPayload, got \(String(describing: caught))")
        }
    }

    // MARK: - Helpers

    private func makeExecutableScript(_ contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActionExecutorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let script = directory.appendingPathComponent("run.sh")
        try contents.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private struct TestTimeout: LocalizedError {
        let seconds: TimeInterval
        var errorDescription: String? { "Test exceeded \(seconds)s hard timeout" }
    }

    private func runWithTimeout(
        seconds: TimeInterval = 10,
        _ work: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
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
