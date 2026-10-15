import AppKit
import Foundation

/// Validates a Jira story URL and reads one from the clipboard. Memory-only:
/// nothing here is fetched.
nonisolated enum JiraIssueConnector {
    enum ConnectionError: LocalizedError, Equatable {
        case invalidURL
        case sessionMissing

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Enter a Jira story URL, e.g. https://jira.example.com/browse/ENG-123"
            case .sessionMissing:
                return "The session no longer exists."
            }
        }
    }

    /// A Jira issue URL. Bare keys and other pages are rejected.
    static func issueURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty,
              JiraSourceContext.parseIssueKey(fromURL: url) != nil else { return nil }
        return url
    }

    /// Clipboard text when that text is itself a Jira story URL. The explicit
    /// URL pasteboard item wins over a plain string. Prose and bare keys are
    /// left for the user to type.
    static func clipboardIssueText(string: String?, urlString: String?) -> String? {
        for candidate in [urlString, string] {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if issueURL(from: trimmed) != nil { return trimmed }
        }
        return nil
    }

    @MainActor
    static func clipboardIssueText(pasteboard: NSPasteboard = .general) -> String? {
        clipboardIssueText(
            string: pasteboard.string(forType: .string),
            urlString: pasteboard.string(forType: .URL)
        )
    }
}
