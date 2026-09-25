import Foundation

/// Matches a spoken push-to-talk utterance to a sidebar destination. The
/// whole utterance must name the destination (optionally after "open", "go
/// to", "show" and similar), so a longer command never navigates by accident.
enum SidebarVoiceNavigation {
    /// Spoken names per destination, including common speech-recognition
    /// spellings of "JIRA" and "GitLab".
    static let phrases: [SidebarSelection: [String]] = [
        .home: ["home", "dashboard"],
        .brief: ["brief", "morning brief", "the brief"],
        .jira: ["jira", "gira", "jeera", "jira board"],
        .mergeRequests: ["gitlab", "git lab", "get lab", "merge requests", "merge request", "mrs"],
        .commands: ["commands", "my commands"],
        .aiProvider: ["ai provider", "a i provider", "provider"],
        .sessions: ["sessions", "session", "claude sessions"],
        .settings: ["settings", "preferences"],
    ]

    private static let leadingVerbs = [
        "go to the", "go to", "goto", "open the", "open up", "open", "show me the", "show me", "show the", "show",
        "switch to the", "switch to", "take me to the", "take me to", "navigate to the", "navigate to",
    ]

    /// The destination the utterance names, or nil. `aiProviderEnabled`
    /// mirrors the sidebar, which hides AI Provider when it is off.
    static func destination(for utterance: String, aiProviderEnabled: Bool) -> SidebarSelection? {
        var text = normalized(utterance)
        for verb in leadingVerbs where text.hasPrefix(verb + " ") {
            text = String(text.dropFirst(verb.count + 1))
            break
        }
        if text.hasSuffix(" please") { text = String(text.dropLast(" please".count)) }
        for selection in SidebarSelection.allCases where selection != .aiProvider || aiProviderEnabled {
            if phrases[selection, default: []].contains(text) { return selection }
        }
        return nil
    }

    /// Lowercased, punctuation-free, single-spaced.
    static func normalized(_ text: String) -> String {
        text.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .joined(separator: " ")
    }
}
