import Foundation

enum JiraSyntheticFixtures {
    struct Fixture {
        let key: String
        let summary: String
        let status: String
        let priority: String
        let updated: String
    }

    static let standardColumns = ["", "Work", "Priority", "Status", "Resolution", "Created", "Updated", "Due date"]

    static let fixtures: [Fixture] = [
        Fixture(key: "SCRUM-21", summary: "Verify signed app evidence before owner trial", status: "Testing", priority: "Lowest", updated: "Aug 21, 2026 at 11:34 PM"),
        Fixture(key: "SCRUM-20", summary: "Add a stale-cards indicator when refresh fails", status: "Testing", priority: "Low", updated: "Aug 21, 2026 at 11:34 PM"),
        Fixture(key: "SCRUM-19", summary: "Terminal bridge drops the first prompt submitted after a cold launch", status: "In Progress", priority: "High", updated: "Aug 21, 2026 at 11:33 PM"),
        Fixture(key: "SCRUM-18", summary: "Trim session transcript before handing context to the builder", status: "Backlog", priority: "Medium", updated: "Aug 21, 2026 at 11:33 PM"),
        Fixture(key: "SCRUM-17", summary: "Route panel refresh through one generation counter", status: "In Review", priority: "High", updated: "Aug 21, 2026 at 11:33 PM"),
        Fixture(key: "SCRUM-16", summary: "Ship the Home quadrant grid behind a feature toggle", status: "In Progress", priority: "Highest", updated: "Aug 21, 2026 at 11:33 PM"),
        Fixture(key: "SCRUM-15", summary: "—", status: "Backlog", priority: "Lowest", updated: "Aug 21, 2026 at 11:32 PM"),
        Fixture(key: "SCRUM-14", summary: "Delimiters , | / : ; ] } must survive extraction", status: "Backlog", priority: "Medium", updated: "Aug 21, 2026 at 11:32 PM"),
        Fixture(key: "SCRUM-13", summary: "Summary mentions SCRUM-999 but keeps its own key", status: "Next Up", priority: "Highest", updated: "Aug 21, 2026 at 11:32 PM"),
        Fixture(key: "SCRUM-12", summary: "Repeated    spaces and\tliteral\ttabs here", status: "Backlog", priority: "Low", updated: "Aug 21, 2026 at 11:31 PM"),
        Fixture(key: "SCRUM-11", summary: String(repeating: "long summary segment ", count: 12), status: "In Review", priority: "Medium", updated: "Aug 21, 2026 at 11:31 PM"),
        Fixture(key: "SCRUM-10", summary: "Bidirectional نص عربي with Latin suffix", status: "Backlog", priority: "Medium", updated: "Aug 21, 2026 at 11:31 PM"),
        Fixture(key: "SCRUM-9", summary: "Diäcrîtîcs çombinéd markś ànd ñ", status: "Backlog", priority: "Low", updated: "Aug 21, 2026 at 11:30 PM"),
        Fixture(key: "SCRUM-8", summary: "Emoji 🚀 CJK 汉字 and em — dash", status: "Backlog", priority: "Medium", updated: "Aug 21, 2026 at 11:30 PM"),
        Fixture(key: "SCRUM-7", summary: "<b>bold</b> & \"quoted\" <script>alert(1)</script>", status: "Next Up", priority: "High", updated: "Aug 21, 2026 at 11:30 PM"),
        Fixture(key: "SCRUM-6", summary: "Fix", status: "Backlog", priority: "Lowest", updated: "Aug 21, 2026 at 11:29 PM"),
    ]

    static let expectedOrder: [String] = Array(fixtures.map(\.key))

    private static func htmlEscaping(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func headerCell(_ label: String) -> String {
        if label.isEmpty {
            return "<th scope=\"col\" class=\"col-checkbox\"></th>"
        }
        return "<th scope=\"col\"><div data-testid=\"native-issue-table.ui.issue-table.header.header-cell.header-cell-container-inline\"><span>\(label)</span><button class=\"sort-affordance\">\(label) • Sort</button></div></th>"
    }

    private static func rowCell(for column: String, fixture: Fixture) -> String? {
        switch column {
        case "":
            return "<td><div data-vc=\"checkbox-cell\"></div></td>"
        case "Work":
            return """
            <th scope="row">
              <div data-testid="native-issue-table.ui.row.issue-row.merged-cell">
                <div data-testid="native-issue-table.common.ui.issue-cells.issue-key.action-container">
                  <a data-testid="native-issue-table.common.ui.issue-cells.issue-key.issue-key-cell" href="/browse/\(fixture.key)">\(fixture.key)</a>
                </div>
                <div data-testid="native-issue-table.common.ui.issue-cells.issue-summary.action-container">
                  <span data-testid="native-issue-table.common.ui.issue-cells.issue-summary.issue-summary-cell">\(htmlEscaping(fixture.summary))</span>
                </div>
              </div>
            </th>
            """
        case "Priority":
            return "<td><div data-testid=\"issue-field-priority-readview-full.ui.priority.wrapper\"><img alt=\"\"><span>\(fixture.priority)</span></div></td>"
        case "Status":
            return "<td><button data-testid=\"issue.fields.status.common.ui.status-lozenge.3\"><span data-testid=\"issue.fields.status.common.ui.status-lozenge.3--content\"><span data-testid=\"issue.fields.status.common.ui.status-lozenge.3--text\">\(fixture.status)</span><span data-testid=\"issue.fields.status.common.ui.status-lozenge.3--chevron\"></span></span></button></td>"
        case "Resolution":
            return "<td><div data-vc=\"native-issue-table-ui-resolution-cell\">Unresolved</div></td>"
        case "Updated":
            return "<td><time>\(fixture.updated)</time></td>"
        case "Created":
            return "<td><time>Aug 21, 2026 at 10:00 AM</time></td>"
        case "Due date":
            return "<td><div>None</div></td>"
        default:
            return nil
        }
    }

    static func listHTML(columns: [String] = standardColumns, duplicateKeyAnchor: Bool = false) -> String {
        let headCells = columns.map(headerCell).joined()
        let bodyRows = fixtures.map { fixture -> String in
            let cells = columns.compactMap { column in
                rowCell(for: column, fixture: fixture)
            }.joined()
            let duplicateAnchor = duplicateKeyAnchor && fixture.key == "SCRUM-16"
                ? "<a href=\"/browse/SCRUM-16\">linked from text</a>"
                : ""
            return """
            <tr data-testid="native-issue-table.ui.issue-row" role="row" data-index="\((fixtures.firstIndex(where: { $0.key == fixture.key }) ?? 0))" data-vc="issue-row">\(cells)\(duplicateAnchor)</tr>
            """
        }.joined()

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head><meta charset="utf-8"><title>Work item search - Jira</title></head>
        <body>
          <main data-testid="issue-navigator-container">
            <table>
              <thead><tr>\(headCells)</tr></thead>
              <tbody>\(bodyRows)</tbody>
            </table>
          </main>
        </body>
        </html>
        """
    }

    static func emptyListHTML(signedIn: Bool = true) -> String {
        let chrome = signedIn
            ? "<nav><button data-testid=\"atlassian-navigation--secondary-actions--profile--trigger\"><img src=\"https://jira.example.com/universal_avatar/view/type/user\" alt=\"\"></button></nav>"
            : "<nav><a href=\"/login\">Log in</a></nav>"
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head><meta charset="utf-8"><title>Work item search - Jira</title></head>
        <body>
          \(chrome)
          <main data-testid="issue-navigator-container">
            <table>
              <thead><tr>\(standardColumns.map(headerCell).joined())</tr></thead>
              <tbody></tbody>
            </table>
            <div>No work items found</div>
          </main>
        </body>
        </html>
        """
    }

    static func authenticationHTML() -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head><meta charset="utf-8"><title>Log in to continue</title></head>
        <body>
          <form action="/login">
            <input type="email" name="username">
            <input type="password" name="password">
            <button type="submit">Continue</button>
          </form>
        </body>
        </html>
        """
    }

    static func dashboardHTML() -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head><meta charset="utf-8"><title>For you - Jira</title></head>
        <body>
          <div data-testid="page-layout.root"><p>Your work digest</p></div>
        </body>
        </html>
        """
    }
}
