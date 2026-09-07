import XCTest
@testable import Console

/// Pure row-packing for the chip FlowLayout (H04-F04 class): the reported
/// width runs to the last item's trailing edge and never includes the
/// inter-item spacing after the final item in a row.
final class FlowLayoutTests: XCTestCase {
    func testWidthExcludesTrailingSpacingAfterLastItem() {
        let result = FlowLayout.arrange(
            widths: [10, 10, 10],
            heights: [5, 5, 5],
            maxWidth: 100,
            spacing: 6
        )
        // Three 10pt capsules with 6pt gaps: 30 + 12, not 30 + 18.
        XCTAssertEqual(result.size.width, 42)
        XCTAssertEqual(result.positions.map(\.x), [0, 16, 32])
    }

    func testSingleItemWidthIsExactlyTheItem() {
        let result = FlowLayout.arrange(widths: [10], heights: [5], maxWidth: 100, spacing: 6)
        XCTAssertEqual(result.size.width, 10)
    }

    func testWrappingCountsInterRowSpacingOnly() {
        let result = FlowLayout.arrange(
            widths: [10, 10, 10],
            heights: [5, 5, 5],
            maxWidth: 30,
            spacing: 6
        )
        // Third item wraps: 20 + 10 > 30.
        XCTAssertEqual(result.positions.map(\.x), [0, 16, 0])
        XCTAssertEqual(result.positions[2].y, 11)
        XCTAssertEqual(result.size.width, 26)
        XCTAssertEqual(result.size.height, 16)
    }

    func testEmptySubviewListHasZeroSize() {
        let result = FlowLayout.arrange(widths: [], heights: [], maxWidth: 100, spacing: 6)
        XCTAssertEqual(result.size, CGSize.zero)
        XCTAssertTrue(result.positions.isEmpty)
    }
}
