import XCTest
@testable import Console

/// Retained-page navigation policy for the shared JIRA web session. Decides
/// whether remounting the JIRA destination may reload the configured list over
/// what the retained page is intentionally showing (a card or deep-link
/// navigation target). Memory-only; no page is created here.
final class JiraWebSessionNavigationTests: XCTestCase {
    private let listURLString = "https://jira.example.com/issues/?jql=assignee=currentUser()"

    private func keeps(
        lastLoaded: String?,
        showingNavigatedPage: Bool = false,
        force: Bool = false
    ) -> Bool {
        JiraWebSession.shouldKeepRetainedPage(
            configuredURLString: listURLString,
            lastLoadedURLString: lastLoaded,
            isShowingNavigatedPage: showingNavigatedPage,
            force: force
        )
    }

    func testNeverLoadedLoadsTheList() {
        XCTAssertFalse(keeps(lastLoaded: nil))
    }
    func testListAlreadyLoadedKeepsRetainedPage() {
        XCTAssertTrue(keeps(lastLoaded: listURLString))
    }

    func testNavigatedIssuePageSurvivesDestinationRemount() {
        XCTAssertTrue(keeps(
            lastLoaded: "https://jira.example.com/browse/DEMO-12",
            showingNavigatedPage: true
        ))
    }

    func testSettingsChangeAlwaysReloads() {
        XCTAssertFalse(keeps(lastLoaded: listURLString, force: true))
        XCTAssertFalse(keeps(
            lastLoaded: "https://jira.example.com/browse/DEMO-12",
            showingNavigatedPage: true,
            force: true
        ))
    }

    func testStaleListRecordAfterUserNavigationReloads() {
        XCTAssertFalse(keeps(lastLoaded: "https://jira.example.com/issues/?jql=other"))
    }
}
