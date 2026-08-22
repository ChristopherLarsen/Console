import Foundation

struct JiraTicketSummary: Identifiable, Equatable, Sendable {
    let key: String
    let summary: String
    let status: String?
    let priority: String?
    let updatedText: String?
    let issueURL: URL
    let sourceOrder: Int

    var id: String { key }
}
