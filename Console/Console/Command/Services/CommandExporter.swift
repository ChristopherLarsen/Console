import Foundation
import AppKit

enum CommandExporter {
    // Serializes a command to a JSON dictionary
    static func toJSON(_ command: Command) -> [String: Any] {
        var json: [String: Any] = [
            "name": command.name,
            "triggerPhrases": command.triggerPhrases,
            "executionMode": command.executionMode.rawValue,
            "requiresConfirmation": command.requiresConfirmation
        ]
        if !command.commandDescription.isEmpty {
            json["description"] = command.commandDescription
        }
        json["actions"] = command.actions.sorted(by: { $0.order < $1.order }).map { action -> [String: Any] in
            var map: [String: Any] = [
                "type": action.type.rawValue,
                "payload": action.payload,
                "order": action.order,
                "delayAfterMS": action.delayAfterMS,
                "timeoutMS": action.timeoutMS,
                "retryOnFailure": action.retryOnFailure
            ]
            if let maxRetries = action.maxRetries {
                map["maxRetries"] = maxRetries
            }
            if let check = action.completionCheck, let object = jsonObject(check) {
                map["completionCheck"] = object
            }
            if let fallback = action.fallbackAction, let object = jsonObject(fallback) {
                map["fallbackAction"] = object
            }
            return map
        }
        return json
    }

    private static func jsonObject<T: Encodable>(_ value: T) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return object as? [String: Any]
    }

    // Full-fidelity serialization for developer round-tripping
    static func toFullJSON(_ command: Command) -> [String: Any] {
        var json = toJSON(command)
        json["shortSummary"] = command.shortSummary
        json["actionDescription"] = command.actionDescription
        json["isEnabled"] = command.isEnabled
        json["isConsole"] = command.isConsole
        json["isProtected"] = command.isProtected
        json["executionCount"] = command.executionCount
        if let catalogVersion = command.catalogVersion {
            json["catalogVersion"] = catalogVersion
        }
        if let lastExecuted = command.lastExecutedAt {
            json["lastExecutedAt"] = ISO8601DateFormatter().string(from: lastExecuted)
        }
        return json
    }

    private static let developerCommandsDirectory: URL = {
        URL(fileURLWithPath: "/Users/christopherlarsen/Workspace/Console/DeveloperCommands", isDirectory: true)
    }()

    static let developerCommandsFile: URL = {
        developerCommandsDirectory.appendingPathComponent("developer_commands.json")
    }()

    @discardableResult
    static func exportAllToFile(_ commands: [Command]) throws -> Int {
        let fm = FileManager.default
        if !fm.fileExists(atPath: developerCommandsDirectory.path) {
            try fm.createDirectory(at: developerCommandsDirectory, withIntermediateDirectories: true)
        }
        let payload = commands.map { toFullJSON($0) }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: developerCommandsFile, options: .atomic)
        return commands.count
    }

    // Copies one or more commands as JSON to the clipboard
    static func copyToClipboard(_ commands: [Command]) -> Bool {
        let payload: Any
        if commands.count == 1, let command = commands.first {
            payload = toJSON(command)
        } else {
            payload = commands.map { toJSON($0) }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let jsonString = String(data: data, encoding: .utf8) else {
            return false
        }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(jsonString, forType: .string)
    }
}
