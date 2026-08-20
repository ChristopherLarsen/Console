import Foundation

/// LLM prompt configuration and response validation for command generation.
///
/// **Expected JSON fields from LLM** (in addition to actions/triggers):
///
/// ```json
/// {
///   "shortSummary": "Opens Gmail in Safari",        // max 60 chars
///   "actionDescription": "This command will:\n• Launch Safari\n• Navigate to Gmail"
/// }
/// ```
///
/// **shortSummary rules**:
/// - Single line, max 60 characters
/// - Concise verb-first description of what the command does
/// - Good: "Opens Gmail in Safari", "Toggles dark mode", "Creates a project folder"
/// - Bad: "This command opens Gmail" (too wordy), "" (empty)
///
/// **actionDescription rules**:
/// - Must start with "This command will:"
/// - Each step as a bullet using the • symbol
/// - One bullet per action step, in execution order
/// - Good: "This command will:\n• Launch Safari\n• Navigate to gmail.com"
/// - Bad: "Opens Safari and goes to Gmail" (no bullets)
enum CommandGeneratorPrompt {
    static let system: String = {
        let catalog = ActionCatalogManager.shared.getCatalog()
        let context = UserContext.current()
        return SystemPrompt.generate(catalog: catalog, userContext: context)
    }()

    static let maxSummaryLength = 60

    // Truncates to 60 chars with "..." if needed; returns "" for blank input
    static func validateShortSummary(_ summary: String) -> String {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.count <= maxSummaryLength { return trimmed }
        return String(trimmed.prefix(maxSummaryLength - 3)) + "..."
    }

    // Ensures "This command will:" header and • bullets; adds them if missing
    static func validateActionDescription(_ description: String) -> String {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var result = trimmed
        if !result.hasPrefix("This command will:") {
            result = "This command will:\n\(result)"
        }
        if !result.contains("•") {
            let lines = result.components(separatedBy: "\n").dropFirst()
            let bulleted = lines.map { line -> String in
                let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return clean.isEmpty ? "" : "• \(clean)"
            }.filter { !$0.isEmpty }
            result = "This command will:\n\(bulleted.joined(separator: "\n"))"
        }
        return result
    }
}
