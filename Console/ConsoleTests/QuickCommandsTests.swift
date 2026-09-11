import XCTest
@testable import Console

final class QuickCommandsTests: XCTestCase {

    // MARK: - Sanitization

    func testSanitizedQuickCommandRejectsBlankEntries() {
        XCTAssertNil(AppSettings.sanitizedQuickCommand(""))
        XCTAssertNil(AppSettings.sanitizedQuickCommand("   "))
        XCTAssertNil(AppSettings.sanitizedQuickCommand("\n\t \n"))
    }

    func testSanitizedQuickCommandRejectsMultilineEntries() {
        XCTAssertNil(AppSettings.sanitizedQuickCommand("one\ntwo"))
        XCTAssertNil(AppSettings.sanitizedQuickCommand("one\rtwo"))
        XCTAssertNil(AppSettings.sanitizedQuickCommand(" /review-mr\n/explain "))
    }

    func testSanitizedQuickCommandTrimsWhitespace() {
        XCTAssertEqual(AppSettings.sanitizedQuickCommand("trailing\n"), "trailing")
        XCTAssertEqual(AppSettings.sanitizedQuickCommand("\rleading"), "leading")
        XCTAssertEqual(AppSettings.sanitizedQuickCommand("  /review-mr  "), "/review-mr")
        XCTAssertEqual(AppSettings.sanitizedQuickCommand("\t/color purple\n"), "/color purple")
        XCTAssertNil(AppSettings.sanitizedQuickCommand(" \n "), "whitespace-only is blank")
    }

    func testSanitizedQuickCommandsPreservesOrderAndCapsAtLimit() {
        let many = (1...15).map { "/cmd \($0)" }
        let sanitized = AppSettings.sanitizedQuickCommands(many)
        XCTAssertEqual(sanitized.count, AppSettings.quickCommandsLimit)
        XCTAssertEqual(sanitized, (1...10).map { "/cmd \($0)" })
    }

    func testSanitizedQuickCommandsDropsInvalidEntriesInPlace() {
        let sanitized = AppSettings.sanitizedQuickCommands([
            " /first ",
            "   ",
            "second\nthird",
            "",
            " /fourth ",
        ])
        XCTAssertEqual(sanitized, ["/first", "/fourth"])
    }

    // MARK: - Encoding / decoding

    func testEncodeDecodeRoundTripPreservesOrder() {
        let commands = ["/review-mr", "/color purple", "/status"]
        let stored = AppSettings.encodeQuickCommands(commands)
        XCTAssertEqual(AppSettings.decodeQuickCommands(from: stored), commands)
    }

    func testDecodeRejectsGarbageAndLegacyValues() {
        XCTAssertEqual(AppSettings.decodeQuickCommands(from: nil), [])
        XCTAssertEqual(AppSettings.decodeQuickCommands(from: ""), [])
        XCTAssertEqual(AppSettings.decodeQuickCommands(from: "not json"), [])
        XCTAssertEqual(AppSettings.decodeQuickCommands(from: "[1, 2, 3]"), [])
        XCTAssertEqual(AppSettings.decodeQuickCommands(from: "\"string\""), [])
    }

    func testDecodeSanitizesAndCapsPersistedValues() {
        let oversized = AppSettings.encodeQuickCommands((1...15).map { "/cmd \($0)" })
        XCTAssertEqual(AppSettings.decodeQuickCommands(from: oversized).count, AppSettings.quickCommandsLimit)

        let mixed = AppSettings.encodeQuickCommands(["keep", "", "drop\nme"])
        XCTAssertEqual(AppSettings.decodeQuickCommands(from: mixed), ["keep"])
    }

    func testEncodeProducesJSONForStorage() {
        let stored = AppSettings.encodeQuickCommands(["/review-mr"])
        XCTAssertTrue(stored.contains("/review-mr"))
        XCTAssertNotNil(stored.data(using: .utf8).flatMap {
            try? JSONDecoder().decode([String].self, from: $0)
        })
    }

    // MARK: - Persistence round trip (simulates @AppStorage)

    func testPersistedValueSurvivesAStoreRoundTrip() throws {
        let suiteName = "QuickCommandsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let commands = ["/review-mr", "/color purple"]
        defaults.set(AppSettings.encodeQuickCommands(commands), forKey: AppSettings.quickCommandsKey)

        let stored = defaults.string(forKey: AppSettings.quickCommandsKey)
        XCTAssertEqual(AppSettings.decodeQuickCommands(from: stored), commands)
    }

    func testEmptyListPersistsAndDecodesToEmpty() {
        let stored = AppSettings.encodeQuickCommands([])
        XCTAssertEqual(stored, "[]")
        XCTAssertEqual(AppSettings.decodeQuickCommands(from: stored), [])
    }

    func testLimitIsTen() {
        XCTAssertEqual(AppSettings.quickCommandsLimit, 10)
        XCTAssertEqual(AppSettings.quickCommandsPlaceholder, "/review-mr")
    }
}
