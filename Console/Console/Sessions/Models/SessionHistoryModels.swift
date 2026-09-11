import Foundation

/// One previous Claude conversation discovered in the local transcript
/// history (`~/.claude/projects/**/<session-id>.jsonl`). Local display data
/// only — nothing here is sent to Claude.
struct SessionHistoryRecord: Identifiable, Equatable {
    let claudeSessionID: UUID
    /// Custom session title first, then the auto summary, then the first
    /// user message.
    let title: String
    let lastActive: Date
    /// Last working directory recorded in the transcript; where a resume
    /// reopens.
    let workingDirectory: URL
    let gitBranch: String?
    /// Transcript file size in bytes.
    let transcriptByteCount: Int64
    /// Ticket key from saved Console associations or a conservative
    /// ticket-style title match; nil for non-ticket sessions.
    let ticketKey: String?
    /// True when the recorded working directory no longer exists.
    let isWorkingDirectoryMissing: Bool

    var id: UUID { claudeSessionID }

    /// White-background cards identify ticket sessions; everything else
    /// renders on the neutral card background.
    var isTicketSession: Bool { ticketKey != nil }
}

/// Where the Previous Sessions modal searches.
enum SessionHistoryScope: Equatable {
    case sessionFolder
    case allProjects
}

/// Conservative ticket recognition for Previous Sessions cards. Only saved
/// Console associations and ticket-style custom titles classify as tickets —
/// a ticket mentioned incidentally in a conversation never colors a card.
nonisolated enum SessionTicketClassification {
    /// Console names new-ticket sessions `S-1234`.
    static func consoleStoryName(_ title: String) -> Bool {
        title.firstMatch(of: /^S-\d+$/) != nil
    }

    /// `SCRUM-9`, `NMA-1234`-style keys appearing in a custom title.
    static func ticketStyleKey(in title: String) -> String? {
        guard let match = title.firstMatch(of: /\b([A-Z][A-Z0-9]{1,15}-\d+)\b/) else { return nil }
        return String(match.1)
    }

    /// Saved associations win; otherwise only a ticket-style custom title
    /// counts — Console's `S-1234` naming or `SCRUM-9`-style keys.
    /// Summaries and first user messages are deliberately ignored so
    /// incidental mentions never classify a session.
    static func ticketKey(
        savedAssociation: String?,
        title: String?,
        isCustomTitle: Bool
    ) -> String? {
        if let savedAssociation, !savedAssociation.isEmpty {
            return savedAssociation
        }
        guard isCustomTitle, let title else { return nil }
        if consoleStoryName(title) { return title }
        return ticketStyleKey(in: title)
    }
}

// MARK: - Display formatting

nonisolated enum SessionHistoryFormatting {
    /// `12.4 KB`, `1.4 MB` — the transcript size shown on cards.
    static func transcriptSize(_ byteCount: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: byteCount)
    }

    /// Relative `last active` label shown on cards.
    static func relativeLastActive(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// Exact date for the hover tooltip.
    static func exactLastActive(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
