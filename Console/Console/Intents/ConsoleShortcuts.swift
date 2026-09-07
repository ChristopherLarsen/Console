import AppIntents

struct ConsoleShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleListeningIntent(),
            phrases: [
                "Toggle listening in \(.applicationName)",
            ],
            shortTitle: "Toggle Listening",
            systemImageName: "waveform"
        )

        AppShortcut(
            intent: StartListeningIntent(),
            phrases: [
                "Start listening in \(.applicationName)",
            ],
            shortTitle: "Start Listening",
            systemImageName: "waveform.badge.mic"
        )

        AppShortcut(
            intent: StopListeningIntent(),
            phrases: [
                "Stop listening in \(.applicationName)",
            ],
            shortTitle: "Stop Listening",
            systemImageName: "waveform.slash"
        )

        AppShortcut(
            intent: StopExecutionIntent(),
            phrases: [
                "Stop command in \(.applicationName)",
            ],
            shortTitle: "Stop Command",
            systemImageName: "stop.fill"
        )

        AppShortcut(
            intent: ExecuteCommandIntent(),
            phrases: [
                "Run a command in \(.applicationName)",
                "Execute a command in \(.applicationName)",
            ],
            shortTitle: "Run Command",
            systemImageName: "play.fill"
        )

        AppShortcut(
            intent: ListCommandsIntent(),
            phrases: [
                "List my \(.applicationName) commands",
                "What commands do I have in \(.applicationName)",
            ],
            shortTitle: "List Commands",
            systemImageName: "list.bullet"
        )

        AppShortcut(
            intent: CreateCommandIntent(),
            phrases: [
                "Create a command in \(.applicationName)",
                "Make a new \(.applicationName) command",
            ],
            shortTitle: "Create Command",
            systemImageName: "plus.circle"
        )

    }
}
