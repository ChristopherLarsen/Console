import XCTest
@testable import Console

final class SidebarRowLabelTests: XCTestCase {
    func testFullLabelStaysWhenTheTextSlotFits() {
        XCTAssertEqual(
            SidebarRowLabel.resolved(full: "Previous Sessions", compact: "Prev Sessions", availableWidth: 160),
            "Previous Sessions"
        )
    }

    func testCompactLabelReplacesFullLabelWhenTheTextSlotIsTooNarrow() {
        XCTAssertEqual(
            SidebarRowLabel.resolved(full: "Previous Sessions", compact: "Prev Sessions", availableWidth: 90),
            "Prev Sessions"
        )
    }

    func testUnknownWidthAndMissingCompactLabelKeepTheFullTitle() {
        XCTAssertEqual(
            SidebarRowLabel.resolved(full: "Previous Sessions", compact: "Prev Sessions", availableWidth: 0),
            "Previous Sessions"
        )
        XCTAssertEqual(
            SidebarRowLabel.resolved(full: "Sessions", compact: nil, availableWidth: 20),
            "Sessions"
        )
    }
}
