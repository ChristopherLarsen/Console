import SwiftUI
import AppKit

/// Renders attributed text content from RTF/HTML when available, falling back to markdown/plain text.
struct AttributedTextView: View {
    let content: String

    var body: some View {
        if let attributed = parseAttributed(content) {
            Text(attributed)
                .textSelection(.enabled)
        } else if let markdown = MarkdownRenderer.parseStyled(content) {
            Text(markdown)
                .textSelection(.enabled)
        } else {
            Text(content)
                .textSelection(.enabled)
        }
    }

    private func parseAttributed(_ string: String) -> AttributedString? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("{\\rtf") {
            return decodeAttributed(data: Data(trimmed.utf8), type: .rtf)
        }

        if looksLikeHTML(trimmed) {
            return decodeAttributed(data: Data(trimmed.utf8), type: .html)
        }

        return nil
    }

    private func looksLikeHTML(_ string: String) -> Bool {
        let lower = string.lowercased()
        return lower.hasPrefix("<!doctype html") ||
            lower.hasPrefix("<html") ||
            lower.contains("<span") ||
            lower.contains("<p>") ||
            lower.contains("<br")
    }

    private func decodeAttributed(data: Data, type: NSAttributedString.DocumentType) -> AttributedString? {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: type,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        guard let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            return nil
        }
        return AttributedString(attributed)
    }
}
