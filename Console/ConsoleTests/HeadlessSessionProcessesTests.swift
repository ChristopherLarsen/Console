import XCTest
@testable import Console

final class HeadlessSessionProcessesTests: XCTestCase {
    func testLegacyConsoleMarkerAndUnrelatedClaude() {
        let id = UUID()
        let args = ["claude", "--session-id", id.uuidString]
        XCTAssertEqual(HeadlessSessionProcesses.classify(arguments: args, executable: "/usr/local/bin/claude", marker: nil)?.owned, false)
        let plugin = "/tmp/console-sessions-\(UUID().uuidString)/plugin"
        let legacy = HeadlessSessionProcesses.classify(arguments: args + ["--plugin-dir", plugin], executable: "/usr/local/bin/claude", marker: nil)
        XCTAssertEqual(legacy?.id, id)
        XCTAssertEqual(legacy?.owned, true)
        XCTAssertNil(HeadlessSessionProcesses.classify(arguments: ["sh", "-c", "claude"], executable: "/bin/sh", marker: id.uuidString))
    }

    func testInheritedMarkerDoesNotClaimDifferentClaudeConversation() {
        let id = UUID()
        let result = HeadlessSessionProcesses.classify(arguments: ["claude", "--resume", id.uuidString],
                                                       executable: "/usr/local/bin/claude", marker: UUID().uuidString)
        XCTAssertEqual(result?.id, id)
        XCTAssertEqual(result?.owned, false)
    }

    func testKernelArgumentDecoderPreservesEmptyArgsAndReadsOnlyOwnershipMarker() throws {
        let id = UUID()
        var argc: Int32 = 4
        var bytes = withUnsafeBytes(of: &argc) { Array($0) }
        bytes += Array("/usr/local/bin/claude\0\0\0claude\0--session-id\0\(id.uuidString)\0\0SECRET=not-returned\0CONSOLE_SESSION_CLAUDE_ID=\(id.uuidString)\0\0".utf8)
        let result = try XCTUnwrap(HeadlessSessionProcesses.decodeArguments(bytes))
        XCTAssertEqual(result.arguments, ["claude", "--session-id", id.uuidString, ""])
        XCTAssertEqual(result.marker, id.uuidString)
        XCTAssertNil(HeadlessSessionProcesses.decodeArguments([0, 0, 0]))
    }

    func testNativeInspectionFindsOwnedOrphanAndRefusesReusedPID() throws {
        let id = UUID()
        // The fixture's parent exits. Its harmless, self-expiring sleep child is
        // adopted by launchd, just like Claude after Console exits unexpectedly.
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        parent.arguments = ["-c", """
        import os
        pid = os.fork()
        if pid == 0:
            os.execve('/bin/sleep', ['claude', '20'], {'CONSOLE_SESSION_CLAUDE_ID': '\(id.uuidString)'})
        print(pid, flush=True)
        """]
        let output = Pipe()
        parent.standardOutput = output
        try parent.run()
        parent.waitUntilExit()
        // Read a line rather than waiting for the child to close inherited stdout.
        let data = output.fileHandleForReading.availableData
        let pid = try XCTUnwrap(Int32(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        let originalIdentity = HeadlessSessionProcesses.identity(for: pid)
        defer {
            if let originalIdentity, HeadlessSessionProcesses.identity(for: pid) == originalIdentity {
                _ = Darwin.kill(pid, SIGKILL)
            }
        }
        let inspector = HeadlessSessionProcesses()
        var found: SessionProcessSnapshot?
        for _ in 0..<20 {
            found = try inspector.snapshot().first { $0.identity.pid == pid }
            if found != nil { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let process = try XCTUnwrap(found)
        XCTAssertEqual(process.parentPID, 1)
        XCTAssertEqual(process.identity, HeadlessSessionProcesses.identity(for: pid))
        let recycled = SessionProcessIdentity(pid: pid, startedSeconds: process.identity.startedSeconds + 1,
                                             startedMicroseconds: process.identity.startedMicroseconds)
        XCTAssertThrowsError(try inspector.signal(SIGTERM, to: recycled))
        XCTAssertTrue(inspector.isRunning(process.identity))
        try inspector.signal(SIGTERM, to: process.identity)
        for _ in 0..<20 {
            if !inspector.isRunning(process.identity) { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertFalse(inspector.isRunning(process.identity))
    }
}
