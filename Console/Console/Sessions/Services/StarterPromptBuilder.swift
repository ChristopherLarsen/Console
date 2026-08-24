import Foundation

/// Pure generation of starter prompts for contextual launches. Prompts contain
/// only the identifier, visible title, and URL that were supplied to the launch
/// flow; unavailable pieces are omitted rather than placeholdered. Nothing here
/// is persisted.
enum StarterPromptBuilder {
    /// The starter prompt for a contextual source, or nil for purposes that
    /// open idle (New Ticket and General).
    static func prompt(for purpose: SessionPurpose, source: SessionLaunchSource?) -> String? {
        guard purpose.generatesStarterPrompt, let source else { return nil }
        switch source {
        case let .jira(key, title, url):
            return jiraPrompt(key: key, title: title, url: url)
        case let .mergeRequest(iid, title, url):
            return mergeRequestPrompt(iid: iid, title: title, url: url)
        }
    }

    private static func jiraPrompt(key: String, title: String?, url: URL?) -> String {
        var lines: [String] = []
        if let title, !title.isEmpty {
            lines.append("Work on Jira ticket \(key): \(title)")
        } else {
            lines.append("Work on Jira ticket \(key)")
        }
        if let url {
            lines.append("Source: \(url.absoluteString)")
        }
        lines.append("")
        lines.append(
            "Inspect the repository and the ticket context available to you, then begin the work. "
                + "If critical ticket details are unavailable, ask me before making assumptions."
        )
        return lines.joined(separator: "\n")
    }

    private static func mergeRequestPrompt(iid: String, title: String?, url: URL) -> String {
        let subject = "GitLab merge request \(iid)"
        var lines: [String] = []
        if let title, !title.isEmpty {
            lines.append("Review \(subject): \(title)")
        } else {
            lines.append("Review \(subject)")
        }
        lines.append("Source: \(url.absoluteString)")
        lines.append("")
        lines.append(
            "Inspect the change diff and report concrete findings prioritized by severity, "
                + "including regressions, security issues, and missing tests. Do not modify files unless I ask."
        )
        return lines.joined(separator: "\n")
    }
}

extension SessionPurpose {
    /// Only these purposes carry a starter prompt; New Ticket and General
    /// open idle by design.
    var generatesStarterPrompt: Bool {
        switch self {
        case .existingTicket, .review:
            return true
        case .newTicket, .general:
            return false
        }
    }
}
