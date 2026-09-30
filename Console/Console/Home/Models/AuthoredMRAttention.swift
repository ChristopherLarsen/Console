import Foundation

/// Structured GitLab evidence from the shared Home scan. Counts are MRs, not notes.
struct AuthoredMRAttention: Codable, Equatable, Identifiable, Sendable {
    var id: URL { url }
    let project: String
    let iid: Int
    let url: URL
    let title: String
    let authorUsername: String
    let state: String
    let unresolvedDiscussionCount: Int
    let externalApprovalCount: Int
    let approvalRulesSatisfied: Bool
    let jiraIssueKey: String?

    /// The scan classifies unresolved threads by whether the author still owes
    /// a response. Missing evidence is never treated as the raw unresolved count.
    var responseRequiredDiscussionCount: Int? = nil

    var needsResponse: Bool { (responseRequiredDiscussionCount ?? 0) > 0 }
    var hasDiscussions: Bool { unresolvedDiscussionCount > 0 }
    var isApproved: Bool { externalApprovalCount > 0 && approvalRulesSatisfied }

    static func decode(_ output: ClaudeOperationOutput, invocation: ClaudeOperationInvocation, scope: URL) throws -> [Self] {
        guard output.correlationID == invocation.correlationID,
              let text = output.resultText, text.utf8.count <= 4_000_000,
              let result = try? JSONDecoder().decode(MRReviewTriageResult.self, from: Data(text.utf8)),
              result.authoredComplete == true, let items = result.authoredItems,
              !result.currentUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MRReviewTriageError.incompleteScan
        }
        var seen = Set<URL>()
        for item in items {
            guard item.iid > 0, item.url.host?.lowercased() == scope.host?.lowercased(),
                  item.url.port == scope.port, item.url.scheme == scope.scheme,
                  item.url.user == nil, item.url.password == nil,
                  item.url.query == nil, item.url.fragment == nil,
                  item.url.path == "/\(item.project)/-/merge_requests/\(item.iid)",
                  seen.insert(item.url).inserted,
                  !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  item.title.count <= 2000, item.unresolvedDiscussionCount >= 0,
                  let responseCount = item.responseRequiredDiscussionCount,
                  responseCount >= 0, responseCount <= item.unresolvedDiscussionCount,
                  item.externalApprovalCount >= 0,
                  item.authorUsername.caseInsensitiveCompare(result.currentUsername) == .orderedSame,
                  item.state == "opened" else { throw MRReviewTriageError.invalidResponse }
        }
        return items.sorted { $0.url.absoluteString < $1.url.absoluteString }
    }
}
