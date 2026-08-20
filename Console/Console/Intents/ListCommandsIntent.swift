import AppIntents
import SwiftData

struct ListCommandsIntent: AppIntent {
    static var title: LocalizedStringResource = "List Commands"
    static var description = IntentDescription("Returns the names of all enabled Console commands.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        guard let container = AppDependencies.shared.modelContainer else {
            throw IntentError.notReady
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
        let names = commands.map(\.name)
        return .result(value: names)
    }
}
