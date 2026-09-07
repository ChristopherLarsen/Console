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
            // Wait for the async start so the reported state is truthful.
            _ = await vm.startListeningAwaited()
        case .stop:
            vm.stopListening()
        case .toggle:
            _ = await vm.toggleListeningAwaited()
        }

        let state = vm.listeningState.isActive ? "on" : "off"
        return .result(value: "Listening is now \(state).")
    }

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$mode) listening")
    }
}

struct StartListeningIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Listening"
    static var description = IntentDescription("Start Console's voice listening.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let vm = AppDependencies.shared.menuBarViewModel else {
            throw IntentError.notReady
        }
        _ = await vm.startListeningAwaited()
        let state = vm.listeningState.isActive ? "on" : "off"
        return .result(value: "Listening is now \(state).")
    }

    static var openAppWhenRun: Bool { false }
}

struct StopListeningIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Listening"
    static var description = IntentDescription("Stop Console's voice listening.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let vm = AppDependencies.shared.menuBarViewModel else {
            throw IntentError.notReady
        }
        vm.stopListening()
        let state = vm.listeningState.isActive ? "on" : "off"
        return .result(value: "Listening is now \(state).")
    }

    static var openAppWhenRun: Bool { false }
}

/// Cancels the in-flight command execution regardless of which entry point
/// started it (voice, Shortcuts, Test runner).
struct StopExecutionIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Command"
    static var description = IntentDescription("Stop the Console command that is currently running.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let vm = AppDependencies.shared.menuBarViewModel else {
            throw IntentError.notReady
        }
        vm.stopExecution()
        return .result(value: "Stop requested.")
    }

    static var openAppWhenRun: Bool { false }
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
