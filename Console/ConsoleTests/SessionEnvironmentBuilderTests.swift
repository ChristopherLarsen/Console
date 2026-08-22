import XCTest
@testable import Console

final class SessionEnvironmentBuilderTests: XCTestCase {

    // MARK: - childEnvironment

    func testBridgeVariablesWinOverEverything() {
        let merged = SessionEnvironmentBuilder.childEnvironment(
            base: ["CONSOLE_TERM_BRIDGE_TOKEN": "stale", "PATH": "/usr/bin"],
            loginShellEnvironment: [
                "CONSOLE_TERM_BRIDGE_TOKEN": "captured",
                "CONSOLE_TERM_BRIDGE_SOCKET": "captured",
            ],
            bridge: ["CONSOLE_TERM_BRIDGE_TOKEN": "real", "CONSOLE_TERM_BRIDGE_SOCKET": "sock"]
        )
        XCTAssertEqual(merged["CONSOLE_TERM_BRIDGE_TOKEN"], "real")
        XCTAssertEqual(merged["CONSOLE_TERM_BRIDGE_SOCKET"], "sock")
    }

    func testSnapshotOverridesBase() {
        let merged = SessionEnvironmentBuilder.childEnvironment(
            base: ["PATH": "/usr/bin:/bin", "HOME": "/Users/x"],
            loginShellEnvironment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
            bridge: [:]
        )
        XCTAssertEqual(merged["PATH"], "/opt/homebrew/bin:/usr/bin:/bin")
        XCTAssertEqual(merged["HOME"], "/Users/x")
    }

    func testTerminalDefaultsAppliedWhenMissing() {
        let merged = SessionEnvironmentBuilder.childEnvironment(
            base: ["HOME": "/Users/x"],
            loginShellEnvironment: nil,
            bridge: [:]
        )
        XCTAssertEqual(merged["TERM"], "xterm-256color")
        XCTAssertEqual(merged["COLORTERM"], "truecolor")
        XCTAssertEqual(merged["LANG"], "en_US.UTF-8")
    }

    func testTerminalDefaultsReplaceInheritedValuesLikeTheDrawerPty() {
        let merged = SessionEnvironmentBuilder.childEnvironment(
            base: ["TERM": "dumb", "COLORTERM": ""],
            loginShellEnvironment: nil,
            bridge: [:]
        )
        XCTAssertEqual(merged["TERM"], "xterm-256color")
        XCTAssertEqual(merged["COLORTERM"], "truecolor")
    }

    func testSnapshotCannotChangeTerminalIdentityButMaySetLocale() {
        let merged = SessionEnvironmentBuilder.childEnvironment(
            base: ["TERM": "dumb"],
            loginShellEnvironment: ["TERM": "xterm-kitty", "LANG": "de_DE.UTF-8"],
            bridge: [:]
        )
        // PTY-provided identity, exactly as the drawer provides it.
        XCTAssertEqual(merged["TERM"], "xterm-256color")
        XCTAssertEqual(merged["COLORTERM"], "truecolor")
        // Locale is legitimately customized by shell rc files.
        XCTAssertEqual(merged["LANG"], "de_DE.UTF-8")
    }

    func testSnapshotArtifactsAndStaleBridgeKeysAreDropped() {
        let merged = SessionEnvironmentBuilder.childEnvironment(
            base: ["PWD": "/console-app-cwd", "_": "/usr/bin/env", "SHLVL": "1"],
            loginShellEnvironment: [
                "PWD": "/tmp/snapshot",
                "OLDPWD": "/tmp",
                "_": "/usr/bin/env",
                "SHLVL": "2",
                "CONSOLE_TERM_BRIDGE_SESSION_ID": "leftover",
                "KEEP": "yes",
            ],
            bridge: ["CONSOLE_TERM_BRIDGE_SESSION_ID": "current"]
        )
        XCTAssertNil(merged["PWD"])
        XCTAssertNil(merged["OLDPWD"])
        XCTAssertNil(merged["_"])
        XCTAssertNil(merged["SHLVL"])
        XCTAssertEqual(merged["CONSOLE_TERM_BRIDGE_SESSION_ID"], "current")
        XCTAssertEqual(merged["KEEP"], "yes")
    }

    func testEmptyValuesDropped() {
        let merged = SessionEnvironmentBuilder.childEnvironment(
            base: ["EMPTY": "", "FINE": "1"],
            loginShellEnvironment: ["ALSO_EMPTY": ""],
            bridge: ["BRIDGE_EMPTY": ""]
        )
        XCTAssertNil(merged["EMPTY"])
        XCTAssertNil(merged["ALSO_EMPTY"])
        XCTAssertNil(merged["BRIDGE_EMPTY"])
        XCTAssertEqual(merged["FINE"], "1")
    }

    // MARK: - captureLoginShellEnvironment

    func testCaptureParsesKeyValueLines() {
        let captured = SessionEnvironmentBuilder.captureLoginShellEnvironment(
            shellPath: "/bin/zsh",
            runner: { executable, arguments in
                XCTAssertEqual(executable, "/bin/zsh")
                XCTAssertEqual(arguments, ["--login", "-c", "/usr/bin/env"])
                return "A=1\nPATH=/a:/b\nEQUALS=v=w\n\nNOEQUALS"
            }
        )
        XCTAssertEqual(captured?["A"], "1")
        XCTAssertEqual(captured?["PATH"], "/a:/b")
        XCTAssertEqual(captured?["EQUALS"], "v=w")
        XCTAssertNil(captured?["NOEQUALS"])
    }

    func testCaptureReturnsNilWhenRunnerFails() {
        let captured = SessionEnvironmentBuilder.captureLoginShellEnvironment(
            shellPath: "/bin/zsh",
            runner: { _, _ in nil }
        )
        XCTAssertNil(captured)
    }

    func testCaptureReturnsNilForEmptyShellPath() {
        var called = false
        let captured = SessionEnvironmentBuilder.captureLoginShellEnvironment(
            shellPath: "",
            runner: { _, _ in
                called = true
                return "A=1"
            }
        )
        XCTAssertFalse(called)
        XCTAssertNil(captured)
    }
}
