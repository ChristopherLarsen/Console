import Foundation
import SwiftData

enum StarterCommandsProvider {
    private struct StarterEntry {
        let name: String
        let phrases: [String]
        let mode: CommandExecutionMode
        let actions: [CommandAction]
        let requiresConfirmation: Bool
        let isConsole: Bool
        let isProtected: Bool
        let shortSummary: String

        init(
            name: String,
            phrases: [String],
            mode: CommandExecutionMode,
            actions: [CommandAction],
            requiresConfirmation: Bool,
            isConsole: Bool,
            isProtected: Bool = false,
            shortSummary: String
        ) {
            self.name = name
            self.phrases = phrases
            self.mode = mode
            self.actions = actions
            self.requiresConfirmation = requiresConfirmation
            self.isConsole = isConsole
            self.isProtected = isProtected
            self.shortSummary = shortSummary
        }
    }

    private static let starterCommands: [StarterEntry] = [
        StarterEntry(
            name: "Recent Commands",
            phrases: ["list", "recent", "show recent"],
            mode: .appIntents,
            actions: [
                CommandAction(type: .appIntent, payload: ConsoleAction.showRecentCommands.rawValue, order: 0)
            ],
            requiresConfirmation: false,
            isConsole: true,
            shortSummary: "Show recent voice commands"
        ),
        StarterEntry(
            name: "Stop Listening",
            phrases: ["off", "stop listening"],
            mode: .appIntents,
            actions: [
                CommandAction(type: .appIntent, payload: ConsoleAction.fishOff.rawValue, order: 0)
            ],
            requiresConfirmation: false,
            isConsole: true,
            shortSummary: "Stop listening for commands"
        ),
        StarterEntry(
            name: "Settings",
            phrases: ["settings", "open settings", "show settings"],
            mode: .appIntents,
            actions: [
                CommandAction(type: .appIntent, payload: ConsoleAction.fishSettings.rawValue, order: 0)
            ],
            requiresConfirmation: false,
            isConsole: true,
            shortSummary: "Open the settings view"
        ),
        StarterEntry(
            name: "Be Quiet",
            phrases: ["be quiet", "quiet", "hush"],
            mode: .appIntents,
            actions: [
                CommandAction(type: .appIntent, payload: ConsoleAction.fishBeQuiet.rawValue, order: 0)
            ],
            requiresConfirmation: false,
            isConsole: true,
            shortSummary: "Turn off audio cues"
        ),
        StarterEntry(
            name: "Make Some Noise",
            phrases: ["make some noise", "makes some noise", "wake up"],
            mode: .appIntents,
            actions: [
                CommandAction(type: .appIntent, payload: ConsoleAction.fishMakeNoise.rawValue, order: 0)
            ],
            requiresConfirmation: false,
            isConsole: true,
            shortSummary: "Turn on audio cues"
        ),
        StarterEntry(
            name: "New Command",
            phrases: ["new command", "create command", "add command"],
            mode: .appIntents,
            actions: [
                CommandAction(type: .appIntent, payload: ConsoleAction.newCommand.rawValue, order: 0)
            ],
            requiresConfirmation: false,
            isConsole: true,
            shortSummary: "Open the command creation form"
        ),
        StarterEntry(
            name: "Note",
            phrases: ["note", "notes", "take a note", "take note", "new note"],
            mode: .appIntents,
            actions: [
                CommandAction(type: .appIntent, payload: ConsoleAction.fishNote.rawValue, order: 0)
            ],
            requiresConfirmation: false,
            isConsole: true,
            isProtected: true,
            shortSummary: "Open the voice note panel"
        ),
    ]

    private static let legacyPayloadMap: [String: String] = [
        "showCommandsTab": ConsoleAction.showRecentCommands.rawValue
    ]

    @MainActor
    static func migratePayloads(in modelContext: ModelContext) {
        let descriptor = FetchDescriptor<Command>(
            predicate: #Predicate<Command> { $0.isConsole }
        )
        guard let commands = try? modelContext.fetch(descriptor) else { return }
        var changed = false
        for command in commands {
            var updated = command.actions
            for i in updated.indices {
                if let newPayload = legacyPayloadMap[updated[i].payload] {
                    updated[i].payload = newPayload
                    changed = true
                }
            }
            if changed { command.actions = updated }
        }
        if changed { try? modelContext.save() }
    }

    /// Removes saved commands that are not Console-owned and not a title-plus-prompt
    /// command. That drops the old operating-system launchers and any user command
    /// whose actions were AppleScript, shell, or an app intent.
    @MainActor
    @discardableResult
    static func deleteNonPromptUserCommands(in modelContext: ModelContext) -> Int {
        let existing = (try? modelContext.fetch(FetchDescriptor<Command>())) ?? []
        var removed = 0
        for command in existing {
            if command.isConsole || command.isClaudePromptCommand { continue }
            modelContext.delete(command)
            removed += 1
        }
        guard removed > 0 else { return 0 }
        do {
            try modelContext.save()
            NotificationCenter.default.post(name: .commandVocabularyDidChange, object: nil)
        } catch {
            printDebug("[Console] Failed to delete legacy commands: \(error)")
        }
        return removed
    }

    @MainActor
    static func loadStarterCommands(into modelContext: ModelContext) -> Int {
        migratePayloads(in: modelContext)
        deleteNonPromptUserCommands(in: modelContext)
        var loaded = 0
        let descriptor = FetchDescriptor<Command>()
        let existingCommands = (try? modelContext.fetch(descriptor)) ?? []
        let existingNames = Set(existingCommands.map(\.name))

        for entry in starterCommands {
            guard !existingNames.contains(entry.name) else { continue }
            let command = Command(
                name: entry.name,
                triggerPhrases: entry.phrases,
                actions: entry.actions,
                executionMode: entry.mode,
                requiresConfirmation: entry.requiresConfirmation,
                catalogVersion: "built-in",
                shortSummary: entry.shortSummary,
                isConsole: entry.isConsole,
                isProtected: entry.isProtected
            )
            modelContext.insert(command)
            loaded += 1
        }

        if loaded > 0 {
            do {
                try modelContext.save()
                printDebug("[Console] Loaded \(loaded) starter commands")
                NotificationCenter.default.post(name: .commandVocabularyDidChange, object: nil)
            } catch {
                printDebug("[Console] Failed to persist starter commands: \(error)")
            }
        }
        return loaded
    }

    // Syncs trigger phrases for built-in Console commands
    @MainActor
    static func syncBuiltInPhrases(in modelContext: ModelContext) {
        let descriptor = FetchDescriptor<Command>(
            predicate: #Predicate<Command> { $0.isConsole }
        )
        let existing = (try? modelContext.fetch(descriptor)) ?? []
        let entryMap = Dictionary(uniqueKeysWithValues: starterCommands.map { ($0.name, $0) })
        var changed = false

        for command in existing {
            guard let entry = entryMap[command.name] else { continue }
            let canonical = Set(entry.phrases)
            let current = Set(command.triggerPhrases)
            if canonical != current {
                command.triggerPhrases = entry.phrases
                changed = true
            }
        }
        if changed {
            try? modelContext.save()
            NotificationCenter.default.post(name: .commandVocabularyDidChange, object: nil)
        }
    }

    @MainActor
    static func hasLoadedStarterCommands(in modelContext: ModelContext) -> Bool {
        let descriptor = FetchDescriptor<Command>()
        let count = (try? modelContext.fetchCount(descriptor)) ?? 0
        return count > 0
    }
}
