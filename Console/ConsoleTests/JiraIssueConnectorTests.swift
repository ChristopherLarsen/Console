import XCTest
@testable import Console

final class JiraIssueConnectorTests: XCTestCase {
    func testIssueURLAcceptsBrowseBoardAndSelectedIssueLinks() {
        let browse = JiraIssueConnector.issueURL(from: "  https://acme.atlassian.net/browse/ENG-123  ")
        XCTAssertEqual(browse?.absoluteString, "https://acme.atlassian.net/browse/ENG-123")

        let board = "https://acme.atlassian.net/jira/software/c/projects/ENG/issues/ENG-123?selectedIssue=ENG-123"
        XCTAssertEqual(JiraIssueConnector.issueURL(from: board)?.absoluteString, board)

        let selected = "https://jira.example.test/secure/RapidBoard.jspa?selectedIssue=AB2-7"
        XCTAssertEqual(JiraIssueConnector.issueURL(from: selected)?.absoluteString, selected)
    }

    func testIssueURLRejectsBareKeysAndNonIssuePages() {
        XCTAssertNil(JiraIssueConnector.issueURL(from: "ENG-123"))
        XCTAssertNil(JiraIssueConnector.issueURL(from: ""))
        XCTAssertNil(JiraIssueConnector.issueURL(from: "see https://acme.atlassian.net/browse/ENG-123"))
        XCTAssertNil(JiraIssueConnector.issueURL(from: "https://acme.atlassian.net/dashboard"))
        XCTAssertNil(JiraIssueConnector.issueURL(from: "https://gitlab.example.test/grp/proj/-/merge_requests/7"))
    }

    func testClipboardPrefersAnExplicitJiraURL() {
        let story = "https://acme.atlassian.net/browse/ENG-123"
        XCTAssertEqual(
            JiraIssueConnector.clipboardIssueText(string: "notes", urlString: story),
            story
        )
        XCTAssertEqual(
            JiraIssueConnector.clipboardIssueText(string: " \(story)\n", urlString: nil),
            story
        )
    }

    func testClipboardIgnoresProseAndBareKeys() {
        XCTAssertNil(JiraIssueConnector.clipboardIssueText(string: "ENG-123", urlString: nil))
        XCTAssertNil(JiraIssueConnector.clipboardIssueText(
            string: "https://acme.atlassian.net/browse/ENG-123 is the story",
            urlString: nil
        ))
        XCTAssertNil(JiraIssueConnector.clipboardIssueText(string: nil, urlString: nil))
    }

    func testClipboardFallsThroughWhenTheURLItemIsNotAStory() {
        let story = "https://acme.atlassian.net/browse/ENG-123"
        XCTAssertEqual(
            JiraIssueConnector.clipboardIssueText(string: story, urlString: "https://example.test/not-jira"),
            story
        )
    }
}
