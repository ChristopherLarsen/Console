import Foundation
import SwiftUI

enum AppleScriptHighlighter {
    private static let keywords: Set<String> = [
        "tell", "end", "to", "set", "get", "if", "then", "else",
        "repeat", "while", "with", "return", "try", "on", "error",
        "property", "global", "local", "my", "of", "in", "not",
        "and", "or", "is", "as", "do", "every", "whose", "where",
        "true", "false", "missing", "value", "count", "copy",
        "application", "activate", "quit", "run", "open", "close",
        "save", "delete", "make", "new", "first", "last", "it",
        "the", "a", "an", "some", "that", "this", "before", "after",
    ]

    private static let builtins: Set<String> = [
        "display", "dialog", "alert", "notification", "shell",
        "script", "log", "beep", "delay", "say", "choose",
        "file", "folder", "path", "name", "volume", "POSIX",
    ]

    static func highlight(_ source: String) -> AttributedString {
        var result = AttributedString()
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)

        for (lineIndex, line) in lines.enumerated() {
            let lineStr = String(line)
            let trimmed = lineStr.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("--") {
                var comment = AttributedString(lineStr)
                comment.foregroundColor = .gray
                result.append(comment)
            } else {
                result.append(highlightLine(lineStr))
            }

            if lineIndex < lines.count - 1 {
                result.append(AttributedString("\n"))
            }
        }

        return result
    }

    private static func highlightLine(_ line: String) -> AttributedString {
        var result = AttributedString()
        var inString = false
        var stringChar: Character = "\""
        var currentToken = ""

        func flushToken() {
            guard !currentToken.isEmpty else { return }
            let lower = currentToken.lowercased()

            var attr = AttributedString(currentToken)
            if keywords.contains(lower) {
                attr.foregroundColor = .purple
                attr.font = .system(.caption, design: .monospaced).bold()
            } else if builtins.contains(lower) {
                attr.foregroundColor = .blue
            } else if let _ = Int(currentToken) {
                attr.foregroundColor = Color.blue
            } else {
                attr.foregroundColor = .primary
            }
            result.append(attr)
            currentToken = ""
        }

        for char in line {
            if inString {
                currentToken.append(char)
                if char == stringChar {
                    var str = AttributedString(currentToken)
                    str.foregroundColor = .red
                    result.append(str)
                    currentToken = ""
                    inString = false
                }
            } else if char == "\"" {
                flushToken()
                inString = true
                stringChar = char
                currentToken.append(char)
            } else if char.isWhitespace || char.isPunctuation && char != "_" {
                flushToken()
                var sep = AttributedString(String(char))
                sep.foregroundColor = .primary
                result.append(sep)
            } else {
                currentToken.append(char)
            }
        }

        if inString {
            var str = AttributedString(currentToken)
            str.foregroundColor = .red
            result.append(str)
        } else {
            flushToken()
        }

        return result
    }
}
