import Foundation

/// Parses the strict AI refinement response format:
///
///     Y1 | <line>
///     Y2 | <line>
///     Y3 | <line>
///     T1 | <task>
///     T2 | <task>
///
/// Tolerant of markdown fencing, blank lines, prose, and missing slots;
/// clamps to the brief's report limits. Returns nil when no yesterday line
/// was recovered (the caller then keeps the local content).
enum BriefAIResponseParser {
    struct Parsed: Equatable {
        var yesterdayLines: [String]
        var todayTasks: [String]
    }

    static func parse(_ response: String) -> Parsed? {
        var yesterday: [String] = []
        var today: [String] = []

        for rawLine in response.split(whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("```") else { continue }
            guard let pipeIndex = trimmed.firstIndex(of: "|") else { continue }
            let tag = trimmed[trimmed.startIndex..<pipeIndex]
                .trimmingCharacters(in: .whitespaces)
                .uppercased()
            guard tag.hasPrefix("Y") || tag.hasPrefix("T") else { continue }
            let content = clean(String(trimmed[trimmed.index(after: pipeIndex)...]))
            guard !content.isEmpty else { continue }
            if tag.hasPrefix("Y") {
                if yesterday.count < MorningBrief.maxYesterdayLines { yesterday.append(content) }
            } else {
                if today.count < MorningBrief.maxTodayTasks { today.append(content) }
            }
        }

        guard !yesterday.isEmpty else { return nil }
        return Parsed(yesterdayLines: yesterday, todayTasks: today)
    }

    /// Strips bullet markers, wrapping quotes, and trailing punctuation noise.
    static func clean(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "• "] where cleaned.hasPrefix(marker) {
            cleaned = String(cleaned.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        if cleaned.count >= 2, cleaned.first == "\"", cleaned.last == "\"" {
            cleaned = String(cleaned.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespaces)
        }
        return BriefComposer.truncate(cleaned, maxLength: BriefComposer.maxLineLength)
    }
}
