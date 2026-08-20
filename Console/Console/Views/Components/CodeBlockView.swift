import SwiftUI
import AppKit

/// Displays fenced code block content with monospace font.
struct CodeBlockView: View {
    let code: String
    let language: String?
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("codeBlockTheme") private var codeBlockThemeRaw: String = AppSettings.CodeBlockTheme.default.rawValue
    @State private var showCopiedFeedback = false

    private var syntaxTheme: SyntaxHighlighter.Theme {
        SyntaxHighlighter.Theme.from(codeBlockThemeRaw: codeBlockThemeRaw)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let language {
                    Text(language)
                        .font(.caption)
                        .foregroundColor(Color.Theme.textSecondary(for: colorScheme))
                }
                Spacer(minLength: 0)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    showCopiedFeedback = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        showCopiedFeedback = false
                    }
                } label: {
                    if showCopiedFeedback {
                        Text("Copied!")
                            .font(.caption)
                            .foregroundColor(Color.Theme.textSecondary(for: colorScheme))
                    } else {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                            .foregroundColor(Color.Theme.textSecondary(for: colorScheme))
                    }
                }
                .buttonStyle(.plain)
                .disabled(showCopiedFeedback)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.Theme.backgroundSecondary(for: colorScheme))

            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                Group {
                    if Self.isSupportedLanguage(language) {
                        Text(SyntaxHighlighter.highlight(code: code, language: language, theme: syntaxTheme))
                    } else {
                        Text(code)
                    }
                }
                .font(.system(size: 14, weight: .regular, design: .monospaced))
                .fixedSize(horizontal: true, vertical: true)
                .padding(12)
            }
            .frame(minHeight: 44)
        }
        .background(Color.Theme.backgroundSecondary(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private static let supportedLanguages: Set<String> = ["swift", "python", "javascript", "js", "json", "bash"]
    private static func isSupportedLanguage(_ lang: String?) -> Bool {
        guard let lang, !lang.isEmpty else { return false }
        return supportedLanguages.contains(lang.lowercased())
    }
}

// MARK: - Code Block Parsing

/// Extracts fenced code blocks from markdown.
enum CodeBlockParser {
    /// Parsed code block with optional language identifier.
    struct Block: Identifiable {
        let id = UUID()
        let language: String?
        let code: String
    }

    /// Finds all ```-delimited code blocks. Returns (language, code) pairs.
    static func extractBlocks(from markdown: String) -> [Block] {
        var blocks: [Block] = []
        let pattern = #"```(\w*)\n?([\s\S]*?)```"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return blocks }
        let range = NSRange(markdown.startIndex..., in: markdown)
        let matches = regex.matches(in: markdown, range: range)
        for match in matches {
            let langRange = Range(match.range(at: 1), in: markdown)
            let codeRange = Range(match.range(at: 2), in: markdown)
            let lang = langRange.flatMap { String(markdown[$0]) }?.trimmingCharacters(in: .whitespaces)
            let code = codeRange.flatMap { String(markdown[$0]) } ?? ""
            blocks.append(Block(language: lang?.isEmpty == true ? nil : lang, code: code))
        }
        return blocks
    }

    /// Segment of parsed content: either markdown text or a code block.
    enum Segment: Identifiable {
        case text(String)
        case code(code: String, language: String?)

        var id: String {
            switch self {
            case .text(let s): return "text-\(s.hashValue)"
            case .code(let c, let l): return "code-\(c.hashValue)-\(l ?? "")"
            }
        }
    }

    /// Splits markdown into alternating text and code segments, preserving order.
    static func parseSegments(from markdown: String) -> [Segment] {
        let pattern = #"```(\w*)\n?([\s\S]*?)```"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return markdown.isEmpty ? [] : [.text(markdown)]
        }
        let range = NSRange(markdown.startIndex..., in: markdown)
        let matches = regex.matches(in: markdown, range: range)
        var segments: [Segment] = []
        var lastEnd = markdown.startIndex

        for match in matches {
            guard let fullRange = Range(match.range, in: markdown),
                  let langRange = Range(match.range(at: 1), in: markdown),
                  let codeRange = Range(match.range(at: 2), in: markdown) else { continue }

            let textBefore = String(markdown[lastEnd..<fullRange.lowerBound])
            if !textBefore.isEmpty {
                segments.append(.text(textBefore))
            }

            let lang = String(markdown[langRange]).trimmingCharacters(in: .whitespaces)
            let code = String(markdown[codeRange])
            segments.append(.code(code: code, language: lang.isEmpty ? nil : lang))
            lastEnd = fullRange.upperBound
        }

        let textAfter = String(markdown[lastEnd...])
        if !textAfter.isEmpty {
            if let incomplete = parseIncompleteCodeBlock(textAfter) {
                if !incomplete.textBefore.isEmpty {
                    segments.append(.text(incomplete.textBefore))
                }
                segments.append(.code(code: incomplete.code, language: incomplete.language))
            } else {
                segments.append(.text(textAfter))
            }
        }

        return segments.isEmpty ? [.text(markdown)] : segments
    }

    /// Handles trailing ``` that opens a code block without a closing fence (e.g. during streaming).
    private static func parseIncompleteCodeBlock(_ text: String) -> (textBefore: String, code: String, language: String?)? {
        guard let fenceRange = text.range(of: "```") else { return nil }
        let afterFence = text[fenceRange.upperBound...]
        let firstNewline = afterFence.firstIndex(of: "\n")
        let langEnd = firstNewline ?? afterFence.endIndex
        let lang = String(afterFence[..<langEnd]).trimmingCharacters(in: .whitespaces)
        let codeStart = firstNewline.map { afterFence.index(after: $0) } ?? afterFence.startIndex
        let code = String(afterFence[codeStart...])
        let textBefore = String(text[..<fenceRange.lowerBound])
        return (textBefore, code, lang.isEmpty ? nil : lang)
    }
}
