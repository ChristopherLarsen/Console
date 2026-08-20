import XCTest

final class AboutHelpUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - About Panel

    func testAboutPanel() throws {
        // XCUITest limitation: Cannot reliably interact with menu bar items
        // Menu bar items have zero hit area and are not accessible to XCTest
        throw XCTSkip("XCUITest cannot access menu bar items - architectural limitation of XCTest framework")
    }
}
