import Foundation

enum SubmissionResult: Equatable, Sendable {
    case submitted
    case rejected(SubmissionRejection)
}

enum SubmissionRejection: Equatable, Sendable {
    case emptyPrompt
    case sessionNotFound
    case sessionNotAcceptingInput
    case processUnavailable
}

/// Pure helpers for the terminal input API.
enum PromptSubmissionEngine {
    static let bracketedPasteStart: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E] // ESC[200~
    static let bracketedPasteEnd: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]   // ESC[201~
    static let returnBytes: [UInt8] = [0x0D]                                       // CR

    /// A prompt is acceptable only when nonempty and the session activity is
    /// Idle or Done (Idle + unread completion).
    static func acceptsPrompt(_ prompt: String, activity: SessionActivity) -> Bool {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch activity {
        case .idle:
            return true
        case .starting, .working, .exited, .error, .unknown:
            return false
        }
    }

    /// Builds the byte sequence for a prompt. Multiline content uses
    /// bracketed-paste wrapping so embedded newlines are not executed; a
    /// trailing Return submits it.
    static func bytes(for prompt: String) -> [UInt8] {
        var bytes: [UInt8] = []
        let content = Array(prompt.utf8)
        if prompt.contains(where: { $0.isNewline }) {
            bytes.append(contentsOf: bracketedPasteStart)
            bytes.append(contentsOf: content)
            bytes.append(contentsOf: bracketedPasteEnd)
        } else {
            bytes.append(contentsOf: content)
        }
        bytes.append(contentsOf: returnBytes)
        return bytes
    }

    /// Byte sequence for a local slash command such as `/color purple`:
    /// plain UTF-8 plus a trailing carriage return. Slash commands are
    /// always single-line.
    static func slashCommandBytes(_ command: String) -> [UInt8] {
        Array(command.utf8) + returnBytes
    }
}
