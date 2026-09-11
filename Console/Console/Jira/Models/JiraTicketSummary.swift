import Foundation

nonisolated struct JiraTicketSummary: Identifiable, Equatable, Sendable {
    let key: String
    let summary: String
    let status: String?
    let priority: String?
    let updatedText: String?
    let issueURL: URL
    let sourceOrder: Int
    /// Host-rendered issue type ("Bug", "Feature", "Story", …); nil when the
    /// board does not expose a type column or icon.
    let issueType: String?

    var id: String { key }

    init(
        key: String,
        summary: String,
        status: String?,
        priority: String?,
        updatedText: String?,
        issueURL: URL,
        sourceOrder: Int,
        issueType: String? = nil
    ) {
        self.key = key
        self.summary = summary
        self.status = status
        self.priority = priority
        self.updatedText = updatedText
        self.issueURL = issueURL
        self.sourceOrder = sourceOrder
        self.issueType = issueType
    }
}
