import Foundation

enum ConsoleCommandRegistry {

    static let all: [ConsoleCommand] = [
            // MARK: - MenuBar Commands (CommandListening mode, priority: .primary)

            ConsoleCommand(
                id: "stop-listening",
                name: "Stop Listening",
                description: "Stop voice listening",
                triggerPhrases: ["off", "stop listening", "stop"],
                availableIn: .primary,
                requiresConfirmation: false,
                contextualCheck: nil,
                handler: {
                    MenuBarViewModel.shared?.stopListening()
                    return .success
                }
            ),

            ConsoleCommand(
                id: "show-settings",
                name: "Show Settings",
                description: "Open the settings panel",
                triggerPhrases: ["settings", "open settings", "show settings"],
                availableIn: .primary,
                requiresConfirmation: false,
                contextualCheck: nil,
                handler: {
                    await MenuBarViewModel.shared?.showSettings()
                    return .success
                }
            ),

            ConsoleCommand(
                id: "show-recent-commands",
                name: "Recent Commands",
                description: "Display recent voice commands",
                triggerPhrases: ["commands", "list", "recent", "show recent", "my commands", "show commands"],
                availableIn: .primary,
                requiresConfirmation: false,
                contextualCheck: nil,
                handler: {
                    await MenuBarViewModel.shared?.showRecentCommands()
                    return .success
                }
            ),

            ConsoleCommand(
                id: "be-quiet",
                name: "Be Quiet",
                description: "Disable sound feedback",
                triggerPhrases: ["be quiet", "quiet", "hush"],
                availableIn: .primary,
                requiresConfirmation: false,
                contextualCheck: nil,
                handler: {
                    await MenuBarViewModel.shared?.disableSoundFeedback()
                    return .success
                }
            ),

            ConsoleCommand(
                id: "make-noise",
                name: "Make Some Noise",
                description: "Enable sound feedback",
                triggerPhrases: ["make some noise", "makes some noise", "make up"],
                availableIn: .primary,
                requiresConfirmation: false,
                contextualCheck: nil,
                handler: {
                    await MenuBarViewModel.shared?.enableSoundFeedback()
                    return .success
                }
            ),

            ConsoleCommand(
                id: "new-command",
                name: "New Command",
                description: "Create a new voice command",
                triggerPhrases: ["new command", "create command", "add command"],
                availableIn: .primary,
                requiresConfirmation: false,
                contextualCheck: nil,
                handler: {
                    await MenuBarViewModel.shared?.showNewCommandCreation()
                    return .success
                }
            ),

            ConsoleCommand(
                id: "take-note",
                name: "Take Note",
                description: "Open note panel for voice dictation",
                triggerPhrases: ["note", "notes", "take a note", "take note", "new note"],
                availableIn: .primary,
                requiresConfirmation: false,
                contextualCheck: nil,
                handler: {
                    MenuBarViewModel.shared?.openNote()
                    return .success
                }
            ),

            // MARK: - Note Voice Commands (NoteDictation exclusive mode)

            ConsoleCommand(
                id: "note-copy",
                name: "Copy",
                description: "Copy note text to clipboard",
                triggerPhrases: ["copy"],
                availableIn: .exclusive,
                requiresConfirmation: false,
                contextualCheck: nil,
                handler: {
                    NoteViewModel.shared?.handleVoiceCommand(.copy)
                    return .success
                }
            ),

            ConsoleCommand(
                id: "note-undo",
                name: "Undo",
                description: "Undo last action in note",
                triggerPhrases: ["undo"],
                availableIn: .exclusive,
                requiresConfirmation: false,
                contextualCheck: nil,
                handler: {
                    NoteViewModel.shared?.handleVoiceCommand(.undo)
                    return .success
                }
            ),

            ConsoleCommand(
                id: "note-done",
                name: "Done",
                description: "Finish editing note",
                triggerPhrases: ["done"],
                availableIn: .exclusive,
                requiresConfirmation: false,
                contextualCheck: nil,
                handler: {
                    NoteViewModel.shared?.handleVoiceCommand(.done)
                    return .success
                }
            ),

            // "edit" command disabled — will return in a future release
            // ConsoleCommand(
            //     id: "note-edit",
            //     name: "Edit",
            //     description: "Toggle note edit mode",
            //     triggerPhrases: ["edit"],
            //     availableIn: .exclusive,
            //     requiresConfirmation: false,
            //     contextualCheck: nil,
            //     handler: {
            //         NoteViewModel.shared?.handleVoiceCommand(.edit)
            //         return .success
            //     }
            // ),

            ConsoleCommand(
                id: "note-clear",
                name: "Clear",
                description: "Clear the note",
                triggerPhrases: ["clear"],
                availableIn: .exclusive,
                requiresConfirmation: false,
                contextualCheck: nil,
                handler: {
                    NoteViewModel.shared?.handleVoiceCommand(.clear)
                    return .success
                }
            ),
    ]

    static func find(by id: String) -> ConsoleCommand? {
        all.first { $0.id == id }
    }
}
