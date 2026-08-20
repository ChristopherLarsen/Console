import Foundation
import SwiftUI

/// Parses markdown into AttributedString preserving newlines and inline styling.
struct MarkdownRenderer {
    private static let inlineOptions = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace
    )

    private static let headerSizes: [Int: CGFloat] = [
        1: 24, 2: 20, 3: 18, 4: 16, 5: 14, 6: 12
    ]

    /// Parses markdown string into AttributedString. Returns nil on failure.
    static func parse(_ markdown: String) -> AttributedString? {
        try? AttributedString(markdown: markdown, options: inlineOptions)
    }

    /// Parses inline markdown per line, applying header styling where detected.
    static func parseStyled(_ markdown: String) -> AttributedString? {
        let collapsed = markdown.replacingOccurrences(of: "\n\n", with: "\n")
        let lines = collapsed.components(separatedBy: "\n")
        guard !lines.isEmpty else { return nil }

        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 {
                result += AttributedString("\n")
            }
            if let (level, content) = parseHeaderLine(line),
               let size = headerSizes[level] {
                var header = parseInline(content)
                header.font = .system(size: size, weight: .bold)
                result += header
            } else {
                result += parseInline(line)
            }
        }
        return result.characters.isEmpty ? nil : result
    }

    private static func parseInline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: inlineOptions)) ?? AttributedString(text)
    }

    private static func parseHeaderLine(_ line: String) -> (level: Int, content: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var level = 0
        for char in trimmed {
            if char == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 6 else { return nil }
        let rest = String(trimmed.dropFirst(level))
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        return (level, rest.trimmingCharacters(in: .whitespaces))
    }
}
