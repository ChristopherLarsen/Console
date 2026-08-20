import XCTest
@testable import Console

final class AppIconResolverTests: XCTestCase {

    // MARK: - Installed App Resolution

    func testReturnsIconForInstalledApp() {
        let icon = AppIconResolver.shared.getIcon(for: "com.apple.finder", size: 32)
        XCTAssertGreaterThan(icon.size.width, 0)
        XCTAssertGreaterThan(icon.size.height, 0)
    }

    func testIconSizeMatchesRequested() {
        let icon = AppIconResolver.shared.getIcon(for: "com.apple.finder", size: 64)
        XCTAssertEqual(icon.size.width, 64, accuracy: 1)
        XCTAssertEqual(icon.size.height, 64, accuracy: 1)
    }

    // MARK: - Fallback for Missing Apps

    func testReturnsFallbackForMissingApp() {
        let icon = AppIconResolver.shared.getIcon(for: "com.nonexistent.fakeapp", size: 32)
        XCTAssertGreaterThan(icon.size.width, 0, "Fallback icon should have nonzero size")
    }

    func testFallbackDoesNotCrash() {
        // Ensures no exception for various invalid bundle IDs
        _ = AppIconResolver.shared.getIcon(for: "", size: 32)
        _ = AppIconResolver.shared.getIcon(for: "invalid", size: 32)
        _ = AppIconResolver.shared.getIcon(for: "a.b.c.d.e.f", size: 48)
    }

    // MARK: - Caching

    func testCachedIconReturnsSameInstance() {
        let first = AppIconResolver.shared.getIcon(for: "com.apple.Safari", size: 32)
        let second = AppIconResolver.shared.getIcon(for: "com.apple.Safari", size: 32)
        XCTAssertTrue(first === second, "Cached icon should return same NSImage instance")
    }

    func testDifferentBundleIDsReturnDifferentIcons() {
        let finder = AppIconResolver.shared.getIcon(for: "com.apple.finder", size: 32)
        let safari = AppIconResolver.shared.getIcon(for: "com.apple.Safari", size: 32)
        XCTAssertFalse(finder === safari, "Different apps should return different icons")
    }

    // MARK: - Resize

    func testResizeProducesCorrectSize() {
        let source = NSImage(size: NSSize(width: 512, height: 512))
        let resized = AppIconResolver.shared.resizeIcon(source, to: 48)
        XCTAssertEqual(resized.size.width, 48, accuracy: 1)
        XCTAssertEqual(resized.size.height, 48, accuracy: 1)
    }

    // MARK: - Thread Safety

    func testConcurrentAccessDoesNotCrash() {
        let expectation = expectation(description: "Concurrent icon access")
        expectation.expectedFulfillmentCount = 10

        for i in 0..<10 {
            DispatchQueue.global().async {
                _ = AppIconResolver.shared.getIcon(for: "com.apple.finder", size: CGFloat(16 + i * 4))
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5)
    }
}
