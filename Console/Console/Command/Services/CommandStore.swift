import Foundation

struct StorableCommand: Codable, Identifiable {
    let id: UUID
    let name: String
    let commandDescription: String
    let triggerPhrases: [String]
    let requiresConfirmation: Bool
    let actions: [CommandAction]
    let catalogVersion: String?
    let shortSummary: String
    let actionDescription: String

    init(
        id: UUID = UUID(),
        name: String,
        commandDescription: String = "",
        triggerPhrases: [String] = [],
        requiresConfirmation: Bool = false,
        actions: [CommandAction] = [],
        catalogVersion: String? = nil,
        shortSummary: String = "",
        actionDescription: String = ""
    ) {
        self.id = id
        self.name = name
        self.commandDescription = commandDescription
        self.triggerPhrases = triggerPhrases
        self.requiresConfirmation = requiresConfirmation
        self.actions = actions
        self.catalogVersion = catalogVersion
        self.shortSummary = shortSummary
        self.actionDescription = actionDescription
    }

    // Decodes with fallback defaults for fields added after initial release
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        commandDescription = try c.decodeIfPresent(String.self, forKey: .commandDescription) ?? ""
        triggerPhrases = try c.decodeIfPresent([String].self, forKey: .triggerPhrases) ?? []
        requiresConfirmation = try c.decodeIfPresent(Bool.self, forKey: .requiresConfirmation) ?? false
        actions = try c.decodeIfPresent([CommandAction].self, forKey: .actions) ?? []
        catalogVersion = try c.decodeIfPresent(String.self, forKey: .catalogVersion)
        shortSummary = try c.decodeIfPresent(String.self, forKey: .shortSummary) ?? ""
        actionDescription = try c.decodeIfPresent(String.self, forKey: .actionDescription) ?? ""
    }
}

@Observable
final class CommandStore: @unchecked Sendable {
    static let shared = CommandStore()

    private(set) var commands: [StorableCommand] = []

    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.console.commandstore")
    private let commandsURL: URL

    private static func resolveCommandsURL() -> URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appFolder = appSupport.appendingPathComponent("Console")
        try? fm.createDirectory(at: appFolder, withIntermediateDirectories: true)
        return appFolder.appendingPathComponent("commands.json")
    }

    private init() {
        commandsURL = Self.resolveCommandsURL()
        loadCommands()
    }

    func getAllCommands() -> [StorableCommand] {
        queue.sync { commands }
    }

    func getCommand(id: UUID) -> StorableCommand? {
        queue.sync { commands.first(where: { $0.id == id }) }
    }

    func saveCommand(_ command: StorableCommand) {
        queue.sync {
            if let index = commands.firstIndex(where: { $0.id == command.id }) {
                commands[index] = command
            } else {
                commands.append(command)
            }
            persistCommands()
        }
    }

    func deleteCommand(id: UUID) {
        queue.sync {
            commands.removeAll(where: { $0.id == id })
            persistCommands()
        }
    }

    func findMatchingCommand(for phrase: String) -> StorableCommand? {
        let lowercased = phrase.lowercased()
        return queue.sync {
            if let exact = commands.first(where: {
                $0.triggerPhrases.map { $0.lowercased() }.contains(lowercased)
            }) {
                return exact
            }
            return commands.first(where: {
                $0.triggerPhrases.contains(where: { trigger in
                    lowercased.contains(trigger.lowercased())
                    || trigger.lowercased().contains(lowercased)
                })
            })
        }
    }

    // MARK: - Persistence

    private func loadCommands() {
        guard fileManager.fileExists(atPath: commandsURL.path) else {
            commands = []
            return
        }
        do {
            let data = try Data(contentsOf: commandsURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            commands = try decoder.decode([StorableCommand].self, from: data)
        } catch {
            printDebug("Error loading commands: \(error)")
            commands = []
        }
    }

    private func persistCommands() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(commands)
            try data.write(to: commandsURL)
        } catch {
            printDebug("Error saving commands: \(error)")
        }
    }
}
