import Foundation

enum CommandActionType: String, Codable, CaseIterable {
    case appIntent
    case appleScript
    case shell

    var displayName: String {
        switch self {
        case .appIntent: return "App Intent"
        case .appleScript: return "AppleScript"
        case .shell: return "Shell"
        }
    }
}

struct CommandAction: Codable, Identifiable, Hashable {
    var id: UUID
    var type: CommandActionType
    var payload: String
    var order: Int
    var delayAfterMS: Int
    var timeoutMS: Int
    var retryOnFailure: Bool
    var maxRetries: Int?
    var completionCheck: CompletionCheck?
    var fallbackAction: FallbackAction?

    init(
        id: UUID = UUID(),
        type: CommandActionType,
        payload: String,
        order: Int = 0,
        delayAfterMS: Int = 500,
        timeoutMS: Int = 5000,
        retryOnFailure: Bool = false,
        maxRetries: Int? = nil,
        completionCheck: CompletionCheck? = nil,
        fallbackAction: FallbackAction? = nil
    ) {
        self.id = id
        self.type = type
        self.payload = payload
        self.order = order
        self.delayAfterMS = delayAfterMS
        self.timeoutMS = timeoutMS
        self.retryOnFailure = retryOnFailure
        self.maxRetries = maxRetries
        self.completionCheck = completionCheck
        self.fallbackAction = fallbackAction
    }

    var actionDescription: String {
        "\(type.displayName): \(payload)"
    }

    /// Value-type copy with a new identity. Every behavioral field is preserved.
    func duplicating(id: UUID = UUID()) -> CommandAction {
        var copy = self
        copy.id = id
        return copy
    }
}

struct FallbackAction: Codable, Hashable {
    let type: CommandActionType
    let payload: String
}

// MARK: - Action Payload Protocol

protocol ActionPayload: Codable {}

struct AppIntentPayload: ActionPayload, Hashable {
    let intentClass: String
    let bundleID: String
    let parameters: [String: AnyCodable]
}

struct AppleScriptPayload: ActionPayload, Hashable {
    let script: String
}

struct ShellPayload: ActionPayload, Hashable {
    let command: String
    let args: [String]
    let workingDirectory: String?
}

// MARK: - AnyCodable

struct AnyCodable: Codable, Hashable {
    let value: AnyHashable

    init(_ value: AnyHashable) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported AnyCodable type"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let int = value as? Int {
            try container.encode(int)
        } else if let double = value as? Double {
            try container.encode(double)
        } else if let string = value as? String {
            try container.encode(string)
        } else if let bool = value as? Bool {
            try container.encode(bool)
        } else {
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "Unsupported AnyCodable type"
                )
            )
        }
    }
}
