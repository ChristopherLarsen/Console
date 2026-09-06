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

    /// Preferred shell constructor: stores executable + argv + cwd as JSON.
    init(
        id: UUID = UUID(),
        shell: ShellPayload,
        order: Int = 0,
        delayAfterMS: Int = 500,
        timeoutMS: Int = 5000,
        retryOnFailure: Bool = false,
        maxRetries: Int? = nil,
        completionCheck: CompletionCheck? = nil,
        fallbackAction: FallbackAction? = nil
    ) {
        self.init(
            id: id,
            type: .shell,
            payload: shell.encodedJSONString(),
            order: order,
            delayAfterMS: delayAfterMS,
            timeoutMS: timeoutMS,
            retryOnFailure: retryOnFailure,
            maxRetries: maxRetries,
            completionCheck: completionCheck,
            fallbackAction: fallbackAction
        )
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

    /// Same representation used by validation and execution.
    func resolvedShellPayload() throws -> ShellPayload {
        try ShellPayload.resolve(payload)
    }

    enum CodingKeys: String, CodingKey {
        case id, type, payload, order, delayAfterMS, timeoutMS
        case retryOnFailure, maxRetries, completionCheck, fallbackAction
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        type = try container.decode(CommandActionType.self, forKey: .type)
        order = try container.decode(Int.self, forKey: .order)
        delayAfterMS = try container.decode(Int.self, forKey: .delayAfterMS)
        timeoutMS = try container.decode(Int.self, forKey: .timeoutMS)
        retryOnFailure = try container.decode(Bool.self, forKey: .retryOnFailure)
        maxRetries = try container.decodeIfPresent(Int.self, forKey: .maxRetries)
        completionCheck = try container.decodeIfPresent(CompletionCheck.self, forKey: .completionCheck)
        fallbackAction = try container.decodeIfPresent(FallbackAction.self, forKey: .fallbackAction)
        payload = try Self.decodePayload(from: container)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(payload, forKey: .payload)
        try container.encode(order, forKey: .order)
        try container.encode(delayAfterMS, forKey: .delayAfterMS)
        try container.encode(timeoutMS, forKey: .timeoutMS)
        try container.encode(retryOnFailure, forKey: .retryOnFailure)
        try container.encodeIfPresent(maxRetries, forKey: .maxRetries)
        try container.encodeIfPresent(completionCheck, forKey: .completionCheck)
        try container.encodeIfPresent(fallbackAction, forKey: .fallbackAction)
    }

    /// Accepts a legacy string or a structured `{command,args,workingDirectory}` object.
    static func decodePayload(from raw: Any) -> String? {
        if let string = raw as? String {
            return string
        }
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    private static func decodePayload(from container: KeyedDecodingContainer<CodingKeys>) throws -> String {
        if let string = try? container.decode(String.self, forKey: .payload) {
            return string
        }
        let structured = try container.decode(ShellPayload.self, forKey: .payload)
        return structured.encodedJSONString()
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

/// Structured process invocation: executable + argument array + working directory.
///
/// This is the execution contract for saved shell actions and for iOS jobs
/// (item 20). iOS jobs must construct argv directly via ``structured(executable:arguments:workingDirectory:)``
/// and pass ``processLaunch`` into ``ProcessRunning``. Do not flatten a job into
/// a shell string, and do not run it with `zsh -c`.
///
/// Decoding accepts either a keyed object or a legacy command-line string.
/// Legacy strings are tokenized with a documented safe subset of quoting;
/// unsupported shell operators fail instead of changing meaning.
struct ShellPayload: ActionPayload, Hashable, Sendable {
    let command: String
    let args: [String]
    let workingDirectory: String?

    init(command: String, args: [String] = [], workingDirectory: String? = nil) {
        self.command = command
        self.args = args
        let trimmed = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.workingDirectory = (trimmed?.isEmpty == false) ? trimmed : nil
    }

    /// Direct argv for iOS jobs and other structured callers. Values are not
    /// parsed as a shell command line.
    static func structured(
        executable: String,
        arguments: [String] = [],
        workingDirectory: String? = nil
    ) -> ShellPayload {
        ShellPayload(command: executable, args: arguments, workingDirectory: workingDirectory)
    }

    /// Resolve a stored action payload: structured JSON object, or a legacy
    /// command-line string using the safe quoting subset.
    static func resolve(_ raw: String) throws -> ShellPayload {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ShellPayloadError.empty }
        if trimmed.hasPrefix("{") {
            guard let data = trimmed.data(using: .utf8) else {
                throw ShellPayloadError.invalidStructuredPayload
            }
            do {
                return try JSONDecoder().decode(ShellPayloadObject.self, from: data).makePayload()
            } catch let error as ShellPayloadError {
                throw error
            } catch {
                throw ShellPayloadError.invalidStructuredPayload
            }
        }
        return try parseLegacyCommandLine(trimmed)
    }

    static func parseLegacyCommandLine(_ line: String) throws -> ShellPayload {
        let tokens = try ShellCommandLineParser.tokenize(line)
        guard let command = tokens.first, !command.isEmpty else {
            throw ShellPayloadError.empty
        }
        return ShellPayload(command: command, args: Array(tokens.dropFirst()), workingDirectory: nil)
    }

    /// Launch specification consumed by ``ProcessRunning``.
    /// Relative names go through `/usr/bin/env` for PATH lookup. Paths that
    /// contain a slash are launched directly so iOS jobs can pass argv unchanged.
    var processLaunch: ProcessLaunchSpec {
        if command.contains("/") {
            return ProcessLaunchSpec(
                executablePath: command,
                arguments: args,
                workingDirectory: workingDirectory
            )
        }
        return ProcessLaunchSpec(
            executablePath: "/usr/bin/env",
            arguments: [command] + args,
            workingDirectory: workingDirectory
        )
    }

    func encodedJSONString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8) else {
            return command
        }
        return text
    }

    enum CodingKeys: String, CodingKey {
        case command, args, workingDirectory
        case executable, arguments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = try Self.parseLegacyCommandLine(string)
            return
        }
        self = try container.decode(ShellPayloadObject.self).makePayload()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(command, forKey: .command)
        try container.encode(args, forKey: .args)
        try container.encodeIfPresent(workingDirectory, forKey: .workingDirectory)
    }
}

/// Keyed object form used by JSONDecoder. Kept private so a command-line string
/// cannot be mistaken for structured JSON.
private struct ShellPayloadObject: Decodable {
    let command: String?
    let executable: String?
    let args: [String]?
    let arguments: [String]?
    let workingDirectory: String?

    func makePayload() throws -> ShellPayload {
        let command = (self.command ?? executable)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !command.isEmpty else {
            throw ShellPayloadError.missingCommand
        }
        return ShellPayload(
            command: command,
            args: args ?? arguments ?? [],
            workingDirectory: workingDirectory
        )
    }
}

/// Values passed to ``ProcessRunning/run(executablePath:arguments:workingDirectory:deadline:)``.
struct ProcessLaunchSpec: Equatable, Sendable {
    let executablePath: String
    let arguments: [String]
    let workingDirectory: String?
}

extension ProcessRunning {
    func run(_ payload: ShellPayload, deadline: Date? = nil) async throws -> ProcessResult {
        let launch = payload.processLaunch
        return try await run(
            executablePath: launch.executablePath,
            arguments: launch.arguments,
            workingDirectory: launch.workingDirectory,
            deadline: deadline
        )
    }
}

enum ShellPayloadError: LocalizedError, Equatable {
    case empty
    case missingCommand
    case unterminatedQuote(String)
    case danglingEscape
    case unsupportedOperator(String)
    case invalidStructuredPayload

    var errorDescription: String? {
        switch self {
        case .empty, .missingCommand:
            return "Shell command cannot be empty"
        case .unterminatedQuote(let quote):
            return "Unterminated \(quote) quote in shell command"
        case .danglingEscape:
            return "Dangling backslash at end of shell command"
        case .unsupportedOperator(let op):
            return "Unsupported shell operator '\(op)'. Console runs an executable with an argument array, not a shell. Pipes, redirection, substitutions, and command chaining are not executed. Use structured arguments and a working directory instead."
        case .invalidStructuredPayload:
            return "Shell payload is not valid structured JSON (command, args, workingDirectory)"
        }
    }
}

// MARK: - Legacy command-line tokenizer
//
// Documented safe subset:
// - Unquoted ASCII spaces and tabs separate arguments.
// - Single quotes preserve every character until the closing quote (`''` is empty).
// - Double quotes preserve characters; `\\`, `\"`, `\$`, and `` \` `` are escapes.
// - Unquoted `\` makes the next character literal, including spaces and operators.
// - Unicode is kept as written.
//
// Unsupported (error before launch; meaning is not rewritten):
// `|`, `&`, `;`, `<`, `>`, `` ` ``, `$(`, `$`, `(`, `)`, and unquoted newlines.

enum ShellCommandLineParser {
    private static let operatorCharacters: Set<Character> = ["|", "&", ";", "<", ">", "`", "(", ")"]

    static func tokenize(_ line: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var inToken = false
        var index = line.startIndex

        func flush() {
            if inToken {
                tokens.append(current)
                current = ""
                inToken = false
            }
        }

        func hasNext() -> Bool { index < line.endIndex }

        func peek() -> Character? {
            guard hasNext() else { return nil }
            return line[index]
        }

        func advance() -> Character {
            let character = line[index]
            index = line.index(after: index)
            return character
        }

        while hasNext() {
            let character = advance()

            switch character {
            case "'":
                inToken = true
                var closed = false
                while hasNext() {
                    let inner = advance()
                    if inner == "'" {
                        closed = true
                        break
                    }
                    current.append(inner)
                }
                if !closed {
                    throw ShellPayloadError.unterminatedQuote("single")
                }

            case "\"":
                inToken = true
                var closed = false
                while hasNext() {
                    let inner = advance()
                    if inner == "\\" {
                        guard hasNext() else { throw ShellPayloadError.danglingEscape }
                        let next = advance()
                        if next == "\n" { continue }
                        if "\\\"$`".contains(next) {
                            current.append(next)
                        } else {
                            current.append("\\")
                            current.append(next)
                        }
                        continue
                    }
                    if inner == "\"" {
                        closed = true
                        break
                    }
                    if inner == "$" {
                        throw ShellPayloadError.unsupportedOperator(dollarOperator(peek: peek()))
                    }
                    if inner == "`" {
                        throw ShellPayloadError.unsupportedOperator("`")
                    }
                    current.append(inner)
                }
                if !closed {
                    throw ShellPayloadError.unterminatedQuote("double")
                }

            case "\\":
                guard hasNext() else { throw ShellPayloadError.danglingEscape }
                inToken = true
                current.append(advance())

            case " ", "\t":
                flush()

            case "\n", "\r":
                throw ShellPayloadError.unsupportedOperator("newline")

            case "$":
                throw ShellPayloadError.unsupportedOperator(dollarOperator(peek: peek()))

            default:
                if operatorCharacters.contains(character) {
                    throw ShellPayloadError.unsupportedOperator(
                        multiCharacterOperator(character, next: peek())
                    )
                }
                inToken = true
                current.append(character)
            }
        }

        flush()
        return tokens
    }

    private static func dollarOperator(peek next: Character?) -> String {
        switch next {
        case "(": return "$("
        case "{": return "${"
        default: return "$"
        }
    }

    private static func multiCharacterOperator(_ character: Character, next: Character?) -> String {
        switch (character, next) {
        case ("&", "&"): return "&&"
        case ("|", "|"): return "||"
        case (">", ">"): return ">>"
        case ("<", "<"): return "<<"
        default: return String(character)
        }
    }
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
