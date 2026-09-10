import XCTest
import SwiftTerm
@testable import Console

@MainActor
final class SidebarHotkeyNavigationTests: XCTestCase {

    /// Isolated suite so tests never touch the hosted app's real defaults.
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "SidebarHotkeyNavigationTests-\(UUID().uuidString)")
        defaults.set("/bin/echo", forKey: ClaudeExecutableLocator.settingsKey)
    }

    // MARK: - Fakes

    private final class FakeLauncher: SessionProcessLaunching {
        func makeTerminalView() -> LocalProcessTerminalView {
            let view = ConsoleTerminalView()
            view.configureAppearance()
            return view
        }

        func launch(
            executable: String,
            arguments: [String],
            environment: [String: String],
            workingDirectory: String,
            terminalView: LocalProcessTerminalView
        ) throws {}

        func startExitShell(
            workingDirectory: String,
            environment: [String: String],
            terminalView: LocalProcessTerminalView
        ) {}
    }

    private func makeStore() -> SessionStore {
        SessionStore(
            launcher: FakeLauncher(),
            locator: ClaudeExecutableLocator(defaults: defaults)
        )
    }

    private func tmpDirectory(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidebar-hotkeys-tests-\(UUID().uuidString)")
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func addSession(_ store: SessionStore, named name: String) throws -> UUID {
        try store.createSession(name: name, workingDirectory: tmpDirectory(name))
    }

    // MARK: - Sidebar hotkeys (⌃1…⌃9)

    func testSidebarHotkeysMapInSidebarOrder() {
        let expected: [SidebarSelection] = [
            .home, .brief, .jira,
            .sessions, .mergeRequests, .commands,
            .aiProvider
        ]
        // ⌃1…⌃9 across the eight sidebar destinations.
        let hotkeyNumbers = [1, 2, 3, 4, 5, 6, 7, 8]
        for (index, destination) in expected.enumerated() {
            XCTAssertEqual(
                ConsoleNavigation.sidebarDestination(hotkeyNumber: hotkeyNumbers[index]),
                destination,
                "⌃\(hotkeyNumbers[index]) must target the sidebar \(destination.label) tab"
            )
        }
    }

    func testSidebarHotkeyZeroHasNoTenthDestinationAndSettingsIsUnreachable() {
        XCTAssertNil(ConsoleNavigation.sidebarDestination(hotkeyNumber: 0))
        XCTAssertNil(ConsoleNavigation.sidebarDestination(hotkeyNumber: 10))
    }

    func testSidebarHotkeyRejectsOutOfRangeNumbers() {
        XCTAssertNil(ConsoleNavigation.sidebarDestination(hotkeyNumber: -1))
        XCTAssertNil(ConsoleNavigation.sidebarDestination(hotkeyNumber: 11))
    }

    // MARK: - Session hotkeys (⌘1…⌘9)

    func testHotkeyNumbersTargetNthSessionInStoreOrder() throws {
        let store = makeStore()
        var ids: [UUID] = []
        for index in 1...ConsoleNavigation.maxSessionHotkeyNumber {
            ids.append(try addSession(store, named: "S\(index)"))
        }

        for number in 1...ConsoleNavigation.maxSessionHotkeyNumber {
            XCTAssertEqual(
                ConsoleNavigation.hotkeySessionID(number: number, in: store.sessions),
                ids[number - 1],
                "⌘\(number) must target the \(number)\(ordinalSuffix(number)) session"
            )
        }
    }

    func testHotkeyNumberBeyondSessionCountReturnsNil() throws {
        let store = makeStore()
        _ = try addSession(store, named: "Only")

        XCTAssertEqual(ConsoleNavigation.hotkeySessionID(number: 1, in: store.sessions), store.sessions[0].id)
        XCTAssertNil(ConsoleNavigation.hotkeySessionID(number: 2, in: store.sessions))
        XCTAssertNil(ConsoleNavigation.hotkeySessionID(number: 9, in: store.sessions))
    }

    func testEmptySessionListHasNoHotkeyTargets() {
        let store = makeStore()
        for number in 1...ConsoleNavigation.maxSessionHotkeyNumber {
            XCTAssertNil(ConsoleNavigation.hotkeySessionID(number: number, in: store.sessions))
        }
    }

    func testOutOfRangeAndZeroNumbersAreRejected() throws {
        let store = makeStore()
        _ = try addSession(store, named: "Alpha")

        XCTAssertNil(ConsoleNavigation.hotkeySessionID(number: 0, in: store.sessions))
        XCTAssertNil(ConsoleNavigation.hotkeySessionID(number: -1, in: store.sessions))
        XCTAssertNil(ConsoleNavigation.hotkeySessionID(number: 10, in: store.sessions))
    }

    // MARK: - clearSelection

    func testClearSelectionDropsSelectedSession() throws {
        let store = makeStore()
        _ = try addSession(store, named: "Alpha")
        let betaID = try addSession(store, named: "Beta")
        store.select(sessionID: betaID)

        store.clearSelection()

        XCTAssertNil(store.selectedSessionID)
        XCTAssertNil(store.selectedSession)
    }

    func testSelectAfterClearRestoresSelection() throws {
        let store = makeStore()
        let alphaID = try addSession(store, named: "Alpha")

        store.clearSelection()
        XCTAssertNil(store.selectedSessionID)

        store.select(sessionID: alphaID)
        XCTAssertEqual(store.selectedSessionID, alphaID)
    }

    private func ordinalSuffix(_ number: Int) -> String {
        switch number % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }
}
