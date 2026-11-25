import Foundation

/// Current state of one merge request, read straight from GitLab with plain
/// read-only `glab api --method GET` calls (no model in the loop). A nil field
/// means that call failed or timed out: unknown, never "no".
nonisolated struct MRLiveFacts: Equatable, Sendable {
    var state: String?
    var headSHA: String?
    /// Usernames with a current approval.
    var approvedBy: [String]?
    var approvedByMe: Bool?
    /// The authenticated user's reviewer state; "not a reviewer" when absent
    /// from the reviewer list.
    var myReviewerState: String?
    /// Unresolved resolvable threads the authenticated user started.
    var myUnresolvedThreads: Int?
    var fetchedAt: Date

    /// One brief line: only what was actually read.
    func briefText(now: Date) -> String {
        var parts: [String] = []
        if let state { parts.append("state \(state)") }
        if let headSHA { parts.append("head \(headSHA.prefix(8))") }
        if let approvedBy {
            let names = approvedBy.isEmpty ? "nobody" : approvedBy.joined(separator: ", ")
            let mine = approvedByMe.map { $0 ? " (you approved)" : " (you have NOT approved)" } ?? ""
            parts.append("approved by \(names)\(mine)")
        } else {
            parts.append("approvals unknown")
        }
        if let myReviewerState { parts.append("your reviewer state: \(myReviewerState)") }
        if let myUnresolvedThreads { parts.append("your unresolved threads: \(myUnresolvedThreads)") }
        let age = max(0, Int(now.timeIntervalSince(fetchedAt)))
        return "GitLab \(age < 60 ? "\(age) s" : "\(age / 60) min") ago: " + parts.joined(separator: ", ")
    }
}

nonisolated enum MRLiveFactsParser {
    static let discussionPageSize = 100

    struct Target: Equatable, Sendable {
        let hostname: String
        /// `projects/<encoded path>/merge_requests/<iid>`
        let endpoint: String
    }

    /// Derives the API target from a merge request web URL
    /// (`https://host/group/project/-/merge_requests/12`).
    static func target(for url: URL) -> Target? {
        guard let host = url.host, url.user == nil, url.password == nil else { return nil }
        let parts = url.path.components(separatedBy: "/-/merge_requests/")
        guard parts.count == 2, let iid = Int(parts[1]), iid > 0 else { return nil }
        let project = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.")
        guard !project.isEmpty, let encoded = project.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return Target(hostname: host + (url.port.map { ":\($0)" } ?? ""),
                      endpoint: "projects/\(encoded)/merge_requests/\(iid)")
    }

    /// The four read-only argument lists for one merge request, in the order
    /// `facts` takes their output.
    static func arguments(for target: Target) -> [[String]] {
        ["", "/approvals", "/reviewers", "/discussions?per_page=\(discussionPageSize)"].map {
            ["api", "--method", "GET", "--hostname", target.hostname, target.endpoint + $0]
        }
    }

    static func facts(mergeRequest: Data?, approvals: Data?, reviewers: Data?, discussions: Data?,
                      username: String?, now: Date) -> MRLiveFacts? {
        func object(_ data: Data?) -> [String: Any]? {
            data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        func array(_ data: Data?) -> [[String: Any]]? {
            data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
        }
        func name(_ entry: [String: Any], _ key: String = "user") -> String? {
            (entry[key] as? [String: Any])?["username"] as? String
        }
        func isMe(_ candidate: String?) -> Bool {
            guard let candidate, let username else { return false }
            return candidate.caseInsensitiveCompare(username) == .orderedSame
        }

        var facts = MRLiveFacts(fetchedAt: now)
        if let mr = object(mergeRequest) {
            facts.state = mr["state"] as? String
            facts.headSHA = mr["sha"] as? String
        }
        if let approvers = object(approvals)?["approved_by"] as? [[String: Any]] {
            let names = approvers.compactMap { name($0) }
            facts.approvedBy = names
            if username != nil { facts.approvedByMe = names.contains(where: isMe) }
        }
        if username != nil, let list = array(reviewers) {
            facts.myReviewerState = list.first { isMe(name($0)) }.map { ($0["state"] as? String) ?? "unknown" }
                ?? "not a reviewer"
        }
        // A full page may hide more threads; report unknown instead of a low count.
        if username != nil, let threads = array(discussions), threads.count < discussionPageSize {
            facts.myUnresolvedThreads = threads.filter { thread in
                guard let notes = thread["notes"] as? [[String: Any]], let first = notes.first,
                      isMe(name(first, "author")) else { return false }
                return notes.contains { ($0["resolvable"] as? Bool) == true && ($0["resolved"] as? Bool) == false }
            }.count
        }
        let readAnything = facts.state != nil || facts.approvedBy != nil
            || facts.myReviewerState != nil || facts.myUnresolvedThreads != nil
        return readAnything ? facts : nil
    }
}

/// Memory-only cache of live merge request facts, refreshed when the
/// Orchestrator's brief is built so no session has to be spawned to learn them.
@MainActor
final class MRLiveFactsStore {
    static let shared = MRLiveFactsStore()
    /// Output of one glab invocation, or nil when it failed.
    typealias Runner = @Sendable (_ executable: String, _ arguments: [String], _ deadline: Date) async -> Data?
    static let maxItems = 5

    private(set) var facts: [URL: MRLiveFacts] = [:]
    private let runner: Runner

    init(runner: @escaping Runner = MRLiveFactsStore.systemRunner) {
        self.runner = runner
    }

    nonisolated static let systemRunner: Runner = { executable, arguments, deadline in
        guard let result = try? await SystemProcessRunner().run(
            executablePath: executable, arguments: arguments, workingDirectory: nil, deadline: deadline
        ), result.succeeded, !result.standardOutputTruncated else { return nil }
        return Data(result.standardOutput.utf8)
    }

    /// Re-reads the first review items within `budget` seconds. Results land
    /// as each merge request finishes; one that fails keeps no stale entry.
    func refresh(items: [MergeRequestSummary], username: String?, executable: String?,
                 budget: TimeInterval) async {
        let targets = items.prefix(Self.maxItems).compactMap { item in
            MRLiveFactsParser.target(for: item.mergeRequestURL).map { (item.mergeRequestURL, $0) }
        }
        facts = facts.filter { entry in targets.contains { $0.0 == entry.key } }
        guard let executable, !targets.isEmpty else { return }
        let deadline = Date().addingTimeInterval(budget)
        let runner = runner
        await withTaskGroup(of: (URL, MRLiveFacts?).self) { group in
            for (url, target) in targets {
                group.addTask {
                    let calls = MRLiveFactsParser.arguments(for: target)
                    async let mr = runner(executable, calls[0], deadline)
                    async let approvals = runner(executable, calls[1], deadline)
                    async let reviewers = runner(executable, calls[2], deadline)
                    async let discussions = runner(executable, calls[3], deadline)
                    return (url, MRLiveFactsParser.facts(
                        mergeRequest: await mr, approvals: await approvals, reviewers: await reviewers,
                        discussions: await discussions, username: username, now: Date()
                    ))
                }
            }
            for await (url, result) in group {
                facts[url] = result
            }
        }
    }
}
