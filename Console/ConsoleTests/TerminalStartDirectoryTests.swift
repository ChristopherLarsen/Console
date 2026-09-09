import XCTest
@testable import Console

/// Terminal start-folder resolution for new Terminal sessions.
final class TerminalStartDirectoryTests: XCTestCase {

    func testNilFallsBackToHome() {
        XCTAssertEqual(
            AppSettings.resolvedTerminalStartDirectory(from: nil),
            NSHomeDirectory()
        )
    }

    func testEmptyAndWhitespaceFallBackToHome() {
        XCTAssertEqual(
            AppSettings.resolvedTerminalStartDirectory(from: ""),
            NSHomeDirectory()
        )
        XCTAssertEqual(
            AppSettings.resolvedTerminalStartDirectory(from: "   "),
            NSHomeDirectory()
        )
    }

    func testDefaultTildeResolvesToHome() {
        XCTAssertEqual(
            AppSettings.resolvedTerminalStartDirectory(from: AppSettings.defaultTerminalFolderDefault),
            NSHomeDirectory()
        )
    }

    func testTildePrefixExpands() {
        let resolved = AppSettings.resolvedTerminalStartDirectory(from: "~/Workspace")
        XCTAssertEqual(resolved, NSHomeDirectory() + "/Workspace")
    }

    func testMissingPathFallsBackToHome() {
        XCTAssertEqual(
            AppSettings.resolvedTerminalStartDirectory(from: "/nonexistent-console-test-path"),
            NSHomeDirectory()
        )
    }

    func testExistingDirectoryResolvesAsIs() {
        let resolved = AppSettings.resolvedTerminalStartDirectory(from: "/tmp")
        XCTAssertEqual(resolved, "/tmp")
    }

    func testFilePathFallsBackToHome() {
        XCTAssertEqual(
            AppSettings.resolvedTerminalStartDirectory(from: "/etc/hosts"),
            NSHomeDirectory()
        )
    }
}
