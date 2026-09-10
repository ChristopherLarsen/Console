import XCTest
@testable import Console

/// One-shot semantics of the Merge Requests handoff (H36-F01 class): a
/// kind-only hint must not stick forever, while a URL handoff keeps its kind
/// pending until the URL is consumed.
@MainActor
final class MergeRequestDeepLinkTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MergeRequestDeepLink.shared.reset()
    }

    override func tearDown() {
        MergeRequestDeepLink.shared.reset()
        super.tearDown()
    }

    func testKindOnlyHintIsOneShot() {
        MergeRequestDeepLink.shared.set(url: nil, kind: .reviewsRequested)

        XCTAssertEqual(MergeRequestDeepLink.shared.consumeKindHint(), .reviewsRequested)
        XCTAssertNil(MergeRequestDeepLink.shared.consumeKindHint(), "A consumed hint must not force the segment again")
        XCTAssertNil(MergeRequestDeepLink.shared.consume(matching: .reviewsRequested))
    }

    func testURLHandoffKeepsKindUntilURLIsConsumed() {
        let url = URL(string: "https://gitlab.example.com/group/project/-/merge_requests/7")!
        MergeRequestDeepLink.shared.set(url: url, kind: .authored)

        // Destination creation consumes the segment hint...
        XCTAssertEqual(MergeRequestDeepLink.shared.consumeKindHint(), .authored)
        // ...and onAppear still lands the URL.
        XCTAssertEqual(MergeRequestDeepLink.shared.consume(matching: .authored), url)
        XCTAssertNil(MergeRequestDeepLink.shared.consume(matching: .authored))
    }

    func testURLHintDoesNotLeakToOtherSegment() {
        let url = URL(string: "https://gitlab.example.com/group/project/-/merge_requests/9")!
        MergeRequestDeepLink.shared.set(url: url, kind: .reviewsRequested)

        XCTAssertEqual(MergeRequestDeepLink.shared.consume(matching: .authored), nil)
        XCTAssertEqual(MergeRequestDeepLink.shared.consume(matching: .reviewsRequested), url)
    }

    // MARK: - New-tab handoff

    func testNewTabHandoffIsOneShot() {
        let url = URL(string: "https://gitlab.example.com/group/project/-/merge_requests/11")!
        MergeRequestDeepLink.shared.setNewTab(url: url)

        XCTAssertEqual(MergeRequestDeepLink.shared.consumeNewTab(), url)
        XCTAssertNil(MergeRequestDeepLink.shared.consumeNewTab(), "A consumed tab handoff must not reopen")
    }

    func testNewTabHandoffIsIndependentOfKindHandoff() {
        let tabURL = URL(string: "https://gitlab.example.com/group/project/-/merge_requests/12")!
        MergeRequestDeepLink.shared.setNewTab(url: tabURL)

        XCTAssertNil(MergeRequestDeepLink.shared.consume(matching: .reviewsRequested))
        XCTAssertNil(MergeRequestDeepLink.shared.consumeKindHint())
        XCTAssertEqual(MergeRequestDeepLink.shared.consumeNewTab(), tabURL)
    }
}
