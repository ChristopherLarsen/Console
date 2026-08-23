import XCTest
@testable import Console

@MainActor
final class ClaudeExecutableLocatorTests: XCTestCase {

    /// Isolated so tests never touch the hosted app's real defaults; a
    /// crashed or interrupted run must not leak an override into Console.
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "ClaudeExecutableLocatorTests-\(UUID().uuidString)")
    }

    func testValidOverrideWinsOverCommonPaths() {
        let locator = ClaudeExecutableLocator(
            shellRunner: { _ in "/bin/echo" },
            defaults: defaults
        )
        locator.storeOverride("/usr/bin/true")
        XCTAssertEqual(locator.locate(), "/usr/bin/true")
        XCTAssertEqual(locator.displayPath(), "/usr/bin/true")
    }

    func testInvalidOverrideIsIgnoredAndFallsBack() {
        let locator = ClaudeExecutableLocator(
            shellRunner: { _ in nil },
            candidateProvider: { [] },
            defaults: defaults
        )
        locator.storeOverride("/nonexistent/claude-binary")
        XCTAssertFalse(locator.isValidExecutable("/nonexistent/claude-binary"))
        // Falls through to common paths and the shell lookup; whatever is
        // located must never be the stale override itself.
        if let located = locator.locate() {
            XCTAssertNotEqual(located, "/nonexistent/claude-binary")
        }
    }

    func testResetToAutomaticClearsOverride() {
        let locator = ClaudeExecutableLocator(
            shellRunner: { _ in nil },
            defaults: defaults
        )
        locator.storeOverride("/usr/bin/true")
        XCTAssertNotNil(locator.storedOverride)
        locator.storeOverride(nil)
        XCTAssertNil(locator.storedOverride)
    }

    func testShellLookupRunsCommandThroughLoginShell() {
        var received: String?
        let locator = ClaudeExecutableLocator(
            shellRunner: { command in
                received = command
                return "/bin/echo"
            },
            candidateProvider: { [] },
            defaults: defaults
        )
        XCTAssertEqual(locator.locate(), "/bin/echo")
        XCTAssertEqual(received, "command -v claude")
    }

    func testCommonPathsCoverKnownLocations() {
        let paths = ClaudeExecutableLocator.commonPaths()
        XCTAssertTrue(paths.contains("\(NSHomeDirectory())/.local/bin/claude"))
        XCTAssertTrue(paths.contains("/usr/local/bin/claude"))
        XCTAssertTrue(paths.contains("/opt/homebrew/bin/claude"))
    }

    func testRealEnvironmentResolvesSomethingUsableOrNothing() {
        // On Christopher's Mac claude exists at ~/.local/bin/claude. This
        // assertion tolerates machines without it.
        let locator = ClaudeExecutableLocator()
        if let path = locator.locate() {
            XCTAssertTrue(locator.isValidExecutable(path))
            XCTAssertTrue(path.hasSuffix("claude"))
        }
    }
}
