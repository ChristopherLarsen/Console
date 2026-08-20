import XCTest
@testable import Console

final class CuratedAppShowcaseTests: XCTestCase {

    // MARK: - App Count

    func testListContainsExactlyTwentyApps() {
        XCTAssertEqual(CuratedAppShowcase.apps.count, 20)
    }

    // MARK: - Popularity Ranking

    func testPopularityRanksAreSequential() {
        let sorted = CuratedAppShowcase.sortedByPopularity
        for (index, app) in sorted.enumerated() {
            XCTAssertEqual(app.popularityRank, index + 1,
                           "\(app.name) should have rank \(index + 1), got \(app.popularityRank)")
        }
    }

    func testSortedByPopularityMatchesRankOrder() {
        let sorted = CuratedAppShowcase.sortedByPopularity
        for i in 0..<sorted.count - 1 {
            XCTAssertLessThan(sorted[i].popularityRank, sorted[i + 1].popularityRank)
        }
    }

    // MARK: - Command Counts

    func testEachAppHasTwoToFiveCommands() {
        for app in CuratedAppShowcase.apps {
            let count = app.showcaseCommands.count
            XCTAssertGreaterThanOrEqual(count, 2,
                                        "\(app.name) has only \(count) command(s)")
            XCTAssertLessThanOrEqual(count, 5,
                                     "\(app.name) has \(count) commands, max is 5")
        }
    }

    func testCommandsAreNotEmpty() {
        for app in CuratedAppShowcase.apps {
            for command in app.showcaseCommands {
                XCTAssertFalse(command.isEmpty, "\(app.name) has an empty command string")
            }
        }
    }

    // MARK: - Uniqueness

    func testNoDuplicateAppIDs() {
        let ids = CuratedAppShowcase.apps.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "Duplicate app IDs found")
    }

    func testNoDuplicateBundleIDs() {
        let bundleIDs = CuratedAppShowcase.apps.map(\.bundleID)
        XCTAssertEqual(bundleIDs.count, Set(bundleIDs).count, "Duplicate bundle IDs found")
    }

    func testNoDuplicatePopularityRanks() {
        let ranks = CuratedAppShowcase.apps.map(\.popularityRank)
        XCTAssertEqual(ranks.count, Set(ranks).count, "Duplicate popularity ranks found")
    }

    // MARK: - Data Integrity

    func testAllAppsHaveValidBundleIDs() {
        for app in CuratedAppShowcase.apps {
            XCTAssertTrue(app.bundleID.contains("."),
                          "\(app.name) has invalid bundleID: \(app.bundleID)")
        }
    }

    func testAllAppsHaveNonEmptyNames() {
        for app in CuratedAppShowcase.apps {
            XCTAssertFalse(app.name.isEmpty)
        }
    }

    func testAllAppsHaveValidCategory() {
        for app in CuratedAppShowcase.apps {
            XCTAssertNotEqual(app.category, .all,
                              "\(app.name) should not use .all as its category")
        }
    }

    // MARK: - AppCategory

    func testAllCategoriesHaveDisplayNames() {
        for category in AppCategory.allCases {
            XCTAssertFalse(category.displayName.isEmpty)
        }
    }

    func testEveryCategoryHasAtLeastOneApp() {
        let usedCategories = Set(CuratedAppShowcase.apps.map(\.category))
        let contentCategories = AppCategory.allCases.filter { $0 != .all }
        for category in contentCategories {
            XCTAssertTrue(usedCategories.contains(category),
                          "No apps in category \(category.displayName)")
        }
    }
}
