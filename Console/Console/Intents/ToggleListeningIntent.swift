import AppIntents

enum ListeningAction: String, AppEnum {
    case start
    case stop
    case toggle

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Listening Mode")

    static var caseDisplayRepresentations: [ListeningAction: DisplayRepresentation] = [
        .start: "Start",
        .stop: "Stop",
        .toggle: "Toggle",
    ]
}

struct ToggleListeningIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Listening"
    static var description = IntentDescription("Start, stop, or toggle Console's voice listening.")

    @Parameter(title: "Mode", default: .toggle)
    var mode: ListeningAction

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let vm = AppDependencies.shared.menuBarViewModel else {
            throw IntentError.notReady
        }

        switch mode {
        case .start:
            vm.startListening()
        case .stop:
            vm.stopListening()
        case .toggle:
            vm.toggleListening()
        }

        let state = vm.listeningState.isActive ? "on" : "off"
        return .result(value: "Listening is now \(state).")
    }

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$mode) listening")
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case notReady
    case commandNotFound(String)
    case noProviderConfigured
    case generationFailed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady:
            "Console is not ready yet. Please open the app and complete setup."
        case .commandNotFound(let name):
            "No enabled command named \"\(name)\" was found."
        case .noProviderConfigured:
            "No AI provider configured. Set one up in Console AI Provider."
        case .generationFailed(let reason):
            "Command generation failed: \(reason)"
        }
    }
}
