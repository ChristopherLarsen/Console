import Foundation
import SwiftData

@Model
final class Command: Identifiable {
    @Attribute(.unique) var id: UUID
    var name: String
    var commandDescription: String
    var triggerPhrases: [String]
    var actions: [CommandAction]
    var executionMode: CommandExecutionMode
    var requiresConfirmation: Bool
    var catalogVersion: String?
    var isEnabled: Bool

    // AI-generated 1-line description (max 60 chars), shown when collapsed
    var shortSummary: String

    // AI-generated markdown bullet list of actions, shown when expanded
    var actionDescription: String

    var executionCount: Int
    var lastExecutedAt: Date?
    var isConsole: Bool
    var isProtected: Bool

    init(
        id: UUID = UUID(),
        name: String,
        commandDescription: String = "",
        triggerPhrases: [String] = [],
        actions: [CommandAction] = [],
        executionMode: CommandExecutionMode = .appIntents,
        requiresConfirmation: Bool = false,
        catalogVersion: String? = nil,
        isEnabled: Bool = true,
        shortSummary: String = "",
        actionDescription: String = "",
        executionCount: Int = 0,
        lastExecutedAt: Date? = nil,
        isConsole: Bool = false,
        isProtected: Bool = false
    ) {
        self.id = id
        self.name = name
        self.commandDescription = commandDescription
        self.triggerPhrases = triggerPhrases
        self.actions = actions
        self.executionMode = executionMode
        self.requiresConfirmation = requiresConfirmation
        self.catalogVersion = catalogVersion
        self.isEnabled = isEnabled
        self.shortSummary = shortSummary
        self.actionDescription = actionDescription
        self.executionCount = executionCount
        self.lastExecutedAt = lastExecutedAt
        self.isConsole = isConsole
        self.isProtected = isProtected
    }

    var isDangerous: Bool { requiresConfirmation }

    /// Returns actionDescription if available, otherwise builds one from actions
    var displayActionDescription: String {
        if !actionDescription.isEmpty { return actionDescription }
        return generatePlaceholderActionDescription()
    }

    // Generates a placeholder summary from trigger phrases and actions
    func generatePlaceholderSummary() -> String {
        if let trigger = triggerPhrases.first {
            let summary = trigger.prefix(57)
            return summary.count < trigger.count ? "\(summary)..." : String(summary)
        }
        return name.isEmpty ? "" : String(name.prefix(60))
    }

    // Generates a placeholder action list from the actions array
    func generatePlaceholderActionDescription() -> String {
        guard !actions.isEmpty else { return "" }
        let bullets = actions.sorted(by: { $0.order < $1.order })
            .map { "• \($0.type.displayName): \($0.payload)" }
            .joined(separator: "\n")
        return "This command will:\n\(bullets)"
    }
}
