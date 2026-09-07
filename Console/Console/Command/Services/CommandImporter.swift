import Foundation
import SwiftData

enum CommandImporter {
    enum ImportError: LocalizedError {
        case invalidJSON
        case missingRequiredFields
        case fileNotFound
        case noImportableCommands

        var errorDescription: String? {
            switch self {
            case .invalidJSON: return "The clipboard does not contain valid JSON."
            case .missingRequiredFields: return "The JSON is missing required fields (name, actions)."
            case .fileNotFound: return "developer_commands.json not found."
            case .noImportableCommands: return "No importable commands were found; existing commands were left unchanged."
            }
        }
    }

    @MainActor
    @discardableResult
    static func importAllFromFile(
        into modelContext: ModelContext,
        fileURL: URL = CommandExporter.developerCommandsFile
    ) throws -> Int {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ImportError.fileNotFound
        }
        let data = try Data(contentsOf: fileURL)
        guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ImportError.invalidJSON
        }

        var commands: [Command] = []
        for json in jsonArray {
            if let command = command(from: json) {
                commands.append(command)
            }
        }
        guard !commands.isEmpty else {
            throw ImportError.noImportableCommands
        }

        try modelContext.delete(model: Command.self)
        for command in commands {
            modelContext.insert(command)
        }
        try modelContext.save()
        NotificationCenter.default.post(name: .commandVocabularyDidChange, object: nil)
        return commands.count
    }

    private static func command(from json: [String: Any]) -> Command? {
        guard let name = json["name"] as? String else { return nil }

        let triggerPhrases = json["triggerPhrases"] as? [String] ?? []
        let modeRaw = json["executionMode"] as? String ?? "appIntents"
        let executionMode = CommandExecutionMode(rawValue: modeRaw) ?? .appIntents
        let requiresConfirmation = json["requiresConfirmation"] as? Bool ?? false
        let description = json["description"] as? String ?? ""
        let shortSummary = json["shortSummary"] as? String ?? ""
        let actionDescription = json["actionDescription"] as? String ?? ""
        let isEnabled = json["isEnabled"] as? Bool ?? true
        let isConsole = json["isConsole"] as? Bool ?? false
        let isProtected = json["isProtected"] as? Bool ?? false
        let catalogVersion = json["catalogVersion"] as? String
        let executionCount = json["executionCount"] as? Int ?? 0

        var lastExecutedAt: Date?
        if let dateStr = json["lastExecutedAt"] as? String {
            lastExecutedAt = ISO8601DateFormatter().date(from: dateStr)
        }

        var actions: [CommandAction] = []
        if let rawActions = json["actions"] as? [[String: Any]] {
            for (index, raw) in rawActions.enumerated() {
                if let action = commandAction(from: raw, index: index) {
                    actions.append(action)
                }
            }
        }
        guard !actions.isEmpty else { return nil }

        return Command(
            name: name,
            commandDescription: description,
            triggerPhrases: triggerPhrases,
            actions: actions,
            executionMode: executionMode,
            requiresConfirmation: requiresConfirmation,
            catalogVersion: catalogVersion,
            isEnabled: isEnabled,
            shortSummary: shortSummary,
            actionDescription: actionDescription,
            executionCount: executionCount,
            lastExecutedAt: lastExecutedAt,
            isConsole: isConsole,
            isProtected: isProtected
        )
    }

    private static func commandAction(from raw: [String: Any], index: Int) -> CommandAction? {
        guard let typeRaw = raw["type"] as? String,
              let type = CommandActionType(rawValue: typeRaw),
              let payloadValue = raw["payload"],
              let payload = payloadString(type: type, from: payloadValue) else { return nil }
        return CommandAction(
            type: type,
            payload: payload,
            order: raw["order"] as? Int ?? index,
            delayAfterMS: raw["delayAfterMS"] as? Int ?? 500,
            timeoutMS: raw["timeoutMS"] as? Int ?? 5000,
            retryOnFailure: raw["retryOnFailure"] as? Bool ?? false,
            maxRetries: raw["maxRetries"] as? Int,
            completionCheck: decodeValue(raw["completionCheck"]),
            fallbackAction: decodeValue(raw["fallbackAction"])
        )
    }

    private static func decodeValue<T: Decodable>(_ raw: Any?) -> T? {
        guard let raw else { return nil }
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    @MainActor
    static func importFromJSON(_ jsonString: String, into modelContext: ModelContext) throws -> Command {
        let trimmed = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImportError.invalidJSON
        }

        guard let name = json["name"] as? String else {
            throw ImportError.missingRequiredFields
        }

        let triggerPhrases = json["triggerPhrases"] as? [String] ?? []
        let modeRaw = json["executionMode"] as? String ?? "appIntents"
        let executionMode = CommandExecutionMode(rawValue: modeRaw) ?? .appIntents

        var actions: [CommandAction] = []
        if let rawActions = json["actions"] as? [[String: Any]] {
            for (index, raw) in rawActions.enumerated() {
                if let action = commandAction(from: raw, index: index) {
                    actions.append(action)
                }
            }
        }

        guard !actions.isEmpty else {
            throw ImportError.missingRequiredFields
        }

        let command = Command(
            name: name,
            triggerPhrases: triggerPhrases,
            actions: actions,
            executionMode: executionMode
        )
        modelContext.insert(command)
        try modelContext.save()
        NotificationCenter.default.post(name: .commandVocabularyDidChange, object: nil)
        return command
    }

    private static func payloadString(type: CommandActionType, from raw: Any) -> String? {
        if type == .shell {
            return CommandAction.decodePayload(from: raw)
        }
        return raw as? String
    }
}
