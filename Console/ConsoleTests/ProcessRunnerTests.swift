import Darwin
import XCTest
@testable import Console

final class ProcessRunnerTests: XCTestCase {

    private let megabytePlusBytes = 1_310_720
    private let ddBlockCount = "1280"
    private var tempDirectories: [URL] = []
    private var pidsToReap: [pid_t] = []

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        executionTimeAllowance = 30
        tempDirectories = []
        pidsToReap = []
    }

    override func tearDown() {
        reapOwnedPIDs()
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
        super.tearDown()
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

    // MARK: - Stop, deadline, force-stop

    func testDefaultForceStopGraceIsTwoSeconds() {
        XCTAssertEqual(ProcessInvocation.defaultForceStopGrace, 2)
    }

    func testCancelBeforeLaunchDoesNotSpawnChild() async throws {
        let directory = try makeTempDirectory()
        let marker = directory.appendingPathComponent("started")
        let pidFile = directory.appendingPathComponent("pid")
        let invocation = ProcessInvocation(
            executablePath: "/bin/sh",
            arguments: ["-c", "echo $$ > '\(pidFile.path)'; echo started > '\(marker.path)'; sleep 60"],
            workingDirectory: nil,
            maxOutputBytesPerStream: 1024
        )
        invocation.requestStop(.cancelled)

        var caught: Error?
        do {
            _ = try await runThrowingWithTimeout {
                try await invocation.startAndWait()
            }
        } catch {
            caught = error
        }

        XCTAssertEqual(caught as? ProcessRunError, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile.path))
    }

    func testTaskCancellationStopsLongRunningProcess() async throws {
        let fixture = try makeScriptFixture(Self.sleepScript)
        let start = Date()
        let task = Task {
            try await SystemProcessRunner().run(
                executablePath: fixture.script.path,
                arguments: [fixture.pidFile.path],
                workingDirectory: nil,
                deadline: nil
            )
        }
        let pid = try await waitForOwnedPID(fixture.pidFile)
        task.cancel()

        var caught: Error?
        do {
            _ = try await runThrowingWithTimeout { try await task.value }
        } catch {
            caught = error
        }

        XCTAssertEqual(caught as? ProcessRunError, .cancelled)
        XCTAssertFalse(OwnedProcessTree.isRunning(pid))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testDeadlineTerminatesAndReportsTimedOut() async throws {
        let fixture = try makeScriptFixture(Self.sleepScript)
        let start = Date()
        var caught: Error?
        do {
            _ = try await runThrowingWithTimeout {
                try await SystemProcessRunner().run(
                    executablePath: fixture.script.path,
                    arguments: [fixture.pidFile.path],
                    workingDirectory: nil,
                    deadline: Date().addingTimeInterval(0.25)
                )
            }
        } catch {
            caught = error
        }

        XCTAssertEqual(caught as? ProcessRunError, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        if let pid = readPID(from: fixture.pidFile) {
            remember(pid)
            XCTAssertFalse(OwnedProcessTree.isRunning(pid))
        }
    }

    func testTERMResistantProcessIsForceStoppedWithinGrace() async throws {
        let fixture = try makeScriptFixture(Self.termResistantScript)
        let start = Date()
        let task = Task {
            try await SystemProcessRunner().run(
                executablePath: fixture.script.path,
                arguments: [fixture.pidFile.path],
                workingDirectory: nil,
                deadline: nil
            )
        }
        let pid = try await waitForOwnedPID(fixture.pidFile)
        task.cancel()

        var caught: Error?
        do {
            _ = try await runThrowingWithTimeout(seconds: 12) { try await task.value }
        } catch {
            caught = error
        }

        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(caught as? ProcessRunError, .cancelled)
        XCTAssertFalse(OwnedProcessTree.isRunning(pid))
        XCTAssertLessThan(elapsed, ProcessInvocation.defaultForceStopGrace + 3)
    }

    func testStopKillsOwnedDescendantsAndLeavesUnrelatedProcess() async throws {
        let fixture = try makeScriptFixture(Self.descendantScript, extraFiles: ["child.pid"])
        let childPIDFile = fixture.directory.appendingPathComponent("child.pid")

        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["60"]
        unrelated.standardOutput = FileHandle.nullDevice
        unrelated.standardError = FileHandle.nullDevice
        try unrelated.run()
        remember(unrelated.processIdentifier)
        defer { stopPID(unrelated.processIdentifier) }

        let task = Task {
            try await SystemProcessRunner().run(
                executablePath: fixture.script.path,
                arguments: [fixture.pidFile.path, childPIDFile.path],
                workingDirectory: nil,
                deadline: nil
            )
        }
        let parentPID = try await waitForOwnedPID(fixture.pidFile)
        let childPID = try await waitForOwnedPID(childPIDFile)
        XCTAssertTrue(OwnedProcessTree.isRunning(unrelated.processIdentifier))

        task.cancel()
        _ = try? await runThrowingWithTimeout { try await task.value }

        XCTAssertFalse(OwnedProcessTree.isRunning(parentPID))
        XCTAssertFalse(OwnedProcessTree.isRunning(childPID))
        XCTAssertTrue(OwnedProcessTree.isRunning(unrelated.processIdentifier))
    }

    func testNextInvocationSucceedsAfterCancel() async throws {
        let fixture = try makeScriptFixture(Self.sleepScript)
        let task = Task {
            try await SystemProcessRunner().run(
                executablePath: fixture.script.path,
                arguments: [fixture.pidFile.path],
                workingDirectory: nil,
                deadline: nil
            )
        }
        _ = try await waitForOwnedPID(fixture.pidFile)
        task.cancel()
        _ = try? await runThrowingWithTimeout { try await task.value }

        let result = try await runWithTimeout {
            try await SystemProcessRunner().run(
                executablePath: "/usr/bin/true",
                arguments: [],
                workingDirectory: nil
            )
        }
        XCTAssertEqual(result.exitCode, 0)
    }

    // MARK: - Fixtures

    private struct ScriptFixture {
        let directory: URL
        let script: URL
        let pidFile: URL
    }

    private static let sleepScript = """
    #!/bin/sh
    echo $$ > "$1"
    exec sleep 60
    """

    private static let termResistantScript = """
    #!/bin/sh
    trap '' TERM
    echo $$ > "$1"
    while :; do
      sleep 1
    done
    """

    private static let descendantScript = """
    #!/bin/sh
    echo $$ > "$1"
    sleep 60 &
    echo $! > "$2"
    wait
    """

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcessRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return directory
    }

    private func makeScriptFixture(_ contents: String, extraFiles: [String] = []) throws -> ScriptFixture {
        let directory = try makeTempDirectory()
        let script = directory.appendingPathComponent("run.sh")
        try contents.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        _ = extraFiles
        return ScriptFixture(
            directory: directory,
            script: script,
            pidFile: directory.appendingPathComponent("pid")
        )
    }

    private func waitForOwnedPID(_ url: URL, timeout: TimeInterval = 2) async throws -> pid_t {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let pid = readPID(from: url) {
                remember(pid)
                return pid
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw TestTimeout(seconds: timeout)
    }

    private func readPID(from url: URL) -> pid_t? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = pid_t(trimmed), value > 1 else { return nil }
        return value
    }

    private func remember(_ pid: pid_t) {
        guard pid > 1 else { return }
        pidsToReap.append(pid)
        for child in OwnedProcessTree.descendantIDs(of: pid) {
            pidsToReap.append(child)
        }
    }

    private func stopPID(_ pid: pid_t) {
        guard pid > 1, pid != getpid(), pid != getppid() else { return }
        _ = kill(pid, SIGKILL)
    }

    private func reapOwnedPIDs() {
        for pid in pidsToReap {
            stopPID(pid)
        }
        pidsToReap.removeAll()
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
        try await runThrowingWithTimeout(seconds: seconds, work)
    }

    private func runThrowingWithTimeout<T: Sendable>(
        seconds: TimeInterval = 10,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
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
