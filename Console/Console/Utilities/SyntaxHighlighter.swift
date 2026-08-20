import Foundation
import SwiftUI

/// Syntax highlighting for code blocks. Supports Swift, Python, JavaScript, JSON, Bash.
struct SyntaxHighlighter {
    enum TokenType {
        case keyword
        case string
        case comment
        case number
    }

    struct Theme {
        let keyword: Color
        let string: Color
        let comment: Color
        let number: Color
        let `default`: Color

        static let `default` = Theme(
            keyword: Color(hex: "AF52DE"),
            string: Color(hex: "D73A49"),
            comment: Color(hex: "6A737D"),
            number: Color(hex: "008080"),
            default: Color.primary
        )

        static let xcode = Theme(
            keyword: Color(hex: "0075C7"),
            string: Color(hex: "52B236"),
            comment: Color(hex: "6A737D"),
            number: Color(hex: "1C00CF"),
            default: Color.primary
        )

        static let github = Theme(
            keyword: Color(hex: "D73A49"),
            string: Color(hex: "22863A"),
            comment: Color(hex: "6A737D"),
            number: Color(hex: "005CC5"),
            default: Color.primary
        )

        static let monokai = Theme(
            keyword: Color(hex: "F92672"),
            string: Color(hex: "A6E22E"),
            comment: Color(hex: "75715E"),
            number: Color(hex: "66D9EF"),
            default: Color.primary
        )

        /// Resolves theme from AppSettings.CodeBlockTheme raw value.
        static func from(codeBlockThemeRaw: String) -> Theme {
            switch codeBlockThemeRaw.lowercased() {
            case "xcode": return .xcode
            case "github": return .github
            case "monokai": return .monokai
            default: return .default
            }
        }
    }

    private static let languageKeywords: [String: Set<String>] = [
        "swift": ["func", "var", "let", "if", "else", "for", "while", "return", "class", "struct", "enum", "protocol", "extension", "import", "in", "as", "try", "catch", "throw", "guard", "switch", "case", "default", "break", "continue", "self", "nil", "true", "false", "async", "await", "throws", "rethrows", "where", "static", "final", "override", "private", "public", "internal", "open"],
        "python": ["def", "class", "if", "elif", "else", "for", "while", "return", "import", "from", "as", "try", "except", "finally", "with", "lambda", "yield", "raise", "pass", "break", "continue", "and", "or", "not", "in", "is", "None", "True", "False"],
        "javascript": ["function", "var", "let", "const", "if", "else", "for", "while", "return", "class", "import", "export", "from", "default", "try", "catch", "finally", "throw", "new", "this", "typeof", "instanceof", "in", "of", "async", "await", "true", "false", "null", "undefined"],
        "json": [],  // JSON has no keywords; highlight keys differently if desired
        "bash": ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "function", "return", "export", "readonly", "local", "echo", "exit", "cd", "pwd", "true", "false"]
    ]

    /// Returns an AttributedString with syntax highlighting applied.
    static func highlight(code: String, language: String?, theme: Theme = .default) -> AttributedString {
        let raw = (language ?? "").lowercased()
        let lang = raw == "js" ? "javascript" : raw
        var result = AttributedString(code)

        // Define regex patterns (order matters: strings and comments first to avoid matching inside them)
        let patterns: [(TokenType, String)] = [
            (.string, #""(?:[^"\\]|\\.)*""#),           // Double-quoted strings
            (.string, #"'(?:[^'\\]|\\.)*'"#),           // Single-quoted strings
            (.string, #"""""(?:[\s\S]*?)"""#),          // Python triple quotes
            (.comment, #"//.*"#),                        // Line comments
            (.comment, #"#.*"#),                         // Shell/Python line comments
            (.comment, #"/\*[\s\S]*?\*/"#),              // Block comments
            (.number, #"\b\d+\.?\d*\b"#),                // Numbers
            (.keyword, #"\b[A-Za-z_][A-Za-z0-9_]*\b"#)  // Identifiers (for keyword check)
        ]

        var highlightedRanges: [(Range<AttributedString.Index>, TokenType)] = []

        for (tokenType, pattern) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsRange = NSRange(code.startIndex..., in: code)
            let matches = regex.matches(in: code, range: nsRange)

            for match in matches {
                guard let range = Range(match.range, in: code),
                      let attrRange = Range(range, in: result) else { continue }

                // Skip if overlapping with already highlighted range
                if highlightedRanges.contains(where: { $0.0.overlaps(attrRange) }) { continue }

                if tokenType == .keyword {
                    let word = String(code[range])
                    let keywords = languageKeywords[lang] ?? languageKeywords["swift"]!
                    if !keywords.contains(word) { continue }
                }

                highlightedRanges.append((attrRange, tokenType))
                let color: Color = switch tokenType {
                case .keyword: theme.keyword
                case .string: theme.string
                case .comment: theme.comment
                case .number: theme.number
                }
                result[attrRange].foregroundColor = color
            }
        }

        return result
    }
}
