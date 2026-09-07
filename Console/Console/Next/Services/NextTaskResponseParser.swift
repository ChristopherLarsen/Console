import Foundation

/// Decodes the AI response for the Next card into a `NextTask`.
///
/// The contract is a single strict JSON object and nothing else:
///
///     {
///       "task": "review_mr" | "address_comments" | "session_attention" | "new_ticket",
///       "headline": "<= 60 chars",
///       "lines": ["...", "...", "..."],
///       "target_url": "https://…" | null,
///       "session_name": "…" | null
///     }
///
/// Tolerant of markdown fencing and surrounding prose; strict about the
/// schema: unknown task values, empty headlines, or more than three lines
/// fail parsing so the caller can fall back to the deterministic pick.
enum NextTaskResponseParser {
    static let maxHeadlineLength = 60
    static let maxLines = 3
    static let maxLineLength = 70

    static func parse(_ response: String) -> NextTask? {
        guard let data = Self.jsonData(in: response) else { return nil }
        return decode(data)
    }

    // MARK: - Decoding

    private struct Payload: Decodable {
        let task: String
        let headline: String
        let lines: [String]
        let target_url: String?
        let session_name: String?
    }

    private static func decode(_ data: Data) -> NextTask? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        guard let kind = NextTaskKind(rawValue: payload.task) else { return nil }

        let headline = clean(payload.headline, maxLength: maxHeadlineLength)
        guard !headline.isEmpty else { return nil }

        // Strict about shape: more than three lines means the model ignored
        // the contract, so fall back rather than silently dropping content.
        guard payload.lines.count <= maxLines else { return nil }
        let lines = payload.lines.compactMap { clean($0, maxLength: maxLineLength) }
        guard !lines.isEmpty else { return nil }

        switch kind {
        case .reviewMergeRequest, .addressComments:
            // MR tasks must carry a deep link.
            guard let urlString = payload.target_url, let url = URL(string: urlString),
                  url.scheme == "https" || url.scheme == "http" else { return nil }
            return NextTask(kind: kind, headline: headline, lines: lines, targetURL: url)
        case .sessionAttention:
            guard let name = payload.session_name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return nil }
            return NextTask(kind: kind, headline: headline, lines: lines, sessionName: name)
        case .ticketWorkflowStep:
            // Workflow steps are local-only; AI payloads must not invent UUID targets.
            return nil
        case .newTicket:
            return NextTask(kind: kind, headline: headline, lines: lines)
        }
    }

    /// Extracts the first JSON object in the response, tolerating markdown
    /// fences and prose around it.
    static func jsonData(in response: String) -> Data? {
        guard let start = response.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < response.endIndex {
            let character = response[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString {
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(response[start...index]).data(using: .utf8)
                    }
                }
            }
            index = response.index(after: index)
        }
        return nil
    }

    /// Collapses whitespace and clamps length so the card never overflows.
    static func clean(_ text: String, maxLength: Int) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard collapsed.count > maxLength else { return collapsed }
        return String(collapsed.prefix(maxLength - 1)).appending("…")
    }
}
