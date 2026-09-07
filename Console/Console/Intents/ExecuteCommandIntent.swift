import AppIntents
import SwiftData

struct CommandNameOptionsProvider: DynamicOptionsProvider {
    @MainActor
    func results() async throws -> [String] {
        guard let container = AppDependencies.shared.modelContainer else {
            return []
        }
        let context = ModelContext(container)
        let includeBuiltIn = UserDefaults.standard.bool(forKey: "enableBuiltInCommands")
        let predicate: Predicate<Command>
        if includeBuiltIn {
            predicate = #Predicate<Command> { $0.isEnabled }
        } else {
            predicate = #Predicate<Command> { $0.isEnabled && $0.catalogVersion == nil }
        }
        var descriptor = FetchDescriptor<Command>(predicate: predicate, sortBy: [SortDescriptor(\.name)])
        descriptor.fetchLimit = 50
        let commands = (try? context.fetch(descriptor)) ?? []
        return commands.map(\.name)
    }
}

struct ExecuteCommandIntent: AppIntent {
    static var title: LocalizedStringResource = "Run Command"
    static var description = IntentDescription("Run a Console command by name.")

    @Parameter(title: "Command Name", optionsProvider: CommandNameOptionsProvider())
    var commandName: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let container = AppDependencies.shared.modelContainer,
              let executor = AppDependencies.shared.localCommandExecutor else {
            throw IntentError.notReady
        }

        let run = try await ExecuteCommandIntentRunner.execute(
            commandName: commandName,
            container: container,
            executor: executor
        )
        return .result(value: ExecuteCommandIntentRunner.statusMessage(for: run))
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$commandName)")
    }
}

@MainActor
enum ExecuteCommandIntentRunner {
    static func execute(
        commandName: String,
        container: ModelContainer,
        executor: any CommandRunning
    ) async throws -> CommandRun {
        let context = ModelContext(container)
        let searchName = commandName
        // Same eligibility as List/voice: hide built-in catalog commands when
        // enableBuiltInCommands is off.
        let includeBuiltIn = UserDefaults.standard.bool(forKey: "enableBuiltInCommands")
        let predicate: Predicate<Command>
        if includeBuiltIn {
            predicate = #Predicate<Command> { $0.isEnabled && $0.name == searchName }
        } else {
            predicate = #Predicate<Command> { $0.isEnabled && $0.name == searchName && $0.catalogVersion == nil }
        }
        var descriptor = FetchDescriptor<Command>(predicate: predicate)
        descriptor.fetchLimit = 1

        guard let command = try? context.fetch(descriptor).first else {
            throw IntentError.commandNotFound(commandName)
        }

        return await executor.execute(command, skipAuthorization: false)
    }

    static func statusMessage(for run: CommandRun) -> String {
        if run.result.alreadyRunning {
            return CommandRun.alreadyRunningMessage
        }
        if run.result.authorizationDenied {
            return "Authorization denied for \"\(run.result.command.name)\"."
        }
        let status = run.result.overallSuccess ? "succeeded" : "failed"
        return "Ran \"\(run.result.command.name)\": \(status)."
    }
}
