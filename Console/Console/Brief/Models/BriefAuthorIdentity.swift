import Foundation

/// Local Git author identity used to attribute Morning Brief activity.
/// Emails are the exact selected identities; additional addresses are aliases.
struct BriefAuthorIdentity: Codable, Equatable, Sendable, Hashable {
    var name: String
    var emails: [String]

    init(name: String = "", emails: [String] = []) {
        self.name = Self.normalizeName(name)
        self.emails = Self.uniqueEmails(emails)
    }

    var isUsable: Bool {
        !normalizedEmails.isEmpty || !name.isEmpty
    }

    var normalizedEmails: Set<String> {
        Set(emails.map(Self.normalizeEmail).filter { !$0.isEmpty })
    }

    var displaySummary: String {
        let emailList = emails.joined(separator: ", ")
        if name.isEmpty { return emailList }
        if emailList.isEmpty { return name }
        return "\(name) <\(emailList)>"
    }

    mutating func addEmail(_ raw: String) {
        emails = Self.uniqueEmails(emails + [raw])
    }

    mutating func removeEmail(_ raw: String) {
        let target = Self.normalizeEmail(raw)
        emails = emails.filter { Self.normalizeEmail($0) != target }
    }

    /// Exact identity match: selected emails (trimmed, case-insensitive),
    /// or an exact name match when no email is selected.
    func matches(authorEmail: String, authorName: String) -> Bool {
        let email = Self.normalizeEmail(authorEmail)
        if !normalizedEmails.isEmpty {
            return !email.isEmpty && normalizedEmails.contains(email)
        }
        let selectedName = name
        return !selectedName.isEmpty && selectedName == Self.normalizeName(authorName)
    }

    static func normalizeEmail(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func normalizeName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func uniqueEmails(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for candidate in raw {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalizeEmail(trimmed)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            ordered.append(trimmed)
        }
        return ordered
    }
}

/// Persisted per-workspace author selection. Defaults come from Git config
/// and stay unconfirmed until the developer accepts or edits them.
struct BriefWorkspaceAuthorSelection: Codable, Equatable, Sendable, Identifiable {
    var workspaceID: UUID
    var identity: BriefAuthorIdentity
    var confirmed: Bool

    var id: UUID { workspaceID }
}

/// Saved workspace fields the Brief collector needs. Avoids coupling
/// collection to session-store mutation.
struct BriefWorkspaceSnapshot: Equatable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var directoryPath: String

    init(id: UUID, name: String, directoryPath: String) {
        self.id = id
        self.name = name
        self.directoryPath = directoryPath
    }

    init(_ workspace: SessionWorkspace) {
        self.init(id: workspace.id, name: workspace.name, directoryPath: workspace.directoryPath)
    }
}
