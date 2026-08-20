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

        let context = ModelContext(container)
        let searchName = commandName
        let predicate = #Predicate<Command> { $0.isEnabled && $0.name == searchName }
        var descriptor = FetchDescriptor<Command>(predicate: predicate)
        descriptor.fetchLimit = 1

        guard let command = try? context.fetch(descriptor).first else {
            throw IntentError.commandNotFound(commandName)
        }

        let result = await executor.execute(command)
        let status = result.overallSuccess ? "succeeded" : "failed"
        return .result(value: "Ran \"\(command.name)\": \(status).")
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$commandName)")
    }
}
