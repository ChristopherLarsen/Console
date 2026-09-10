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
