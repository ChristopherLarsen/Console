import Foundation

/// Display helpers for the text a command sends to Claude.
enum CommandPromptText {
    /// The first non-empty lines of a prompt, used as the row hint.
    static func hint(from prompt: String, lineCount: Int = 2) -> String {
        let lines = prompt
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.prefix(max(lineCount, 0)).joined(separator: "\n")
    }
}
