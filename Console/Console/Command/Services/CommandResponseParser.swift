import Foundation

enum CommandResponseParser {
    @MainActor
    static func parse(_ jsonString: String) throws -> Command {
        let trimmed = stripCodeFences(jsonString.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let data = trimmed.data(using: .utf8) else {
            throw LLMGeneratorError.decodingFailed("Response is not valid UTF-8")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMGeneratorError.decodingFailed("Response is not valid JSON")
        }

        // Check if response is an error instead of a command
        if let errorType = json["error"] as? String {
            let errorMessage = json["error_message"] as? String ?? "Unknown error occurred"
            let suggestion = json["suggestion"] as? String

            switch errorType {
            case "NOT_AVAILABLE":
                throw LLMGeneratorError.notAvailable(message: errorMessage, suggestion: suggestion)
            case "AMBIGUOUS_REQUEST":
                throw LLMGeneratorError.ambiguousRequest(message: errorMessage, suggestion: suggestion)
            case "TOO_COMPLEX":
                throw LLMGeneratorError.tooComplex(message: errorMessage, suggestion: suggestion)
            case "UNSAFE":
                throw LLMGeneratorError.safetyExceeded(message: errorMessage, suggestion: suggestion)
            case "SAFETY_EXCEEDED":
                throw LLMGeneratorError.safetyExceeded(message: errorMessage, suggestion: suggestion)
            default:
                throw LLMGeneratorError.unknownError(message: errorMessage)
            }
        }

        // Normal command parsing
        guard let name = json["name"] as? String
                ?? json["command_name"] as? String else {
            throw LLMGeneratorError.decodingFailed("Missing 'name' field")
        }

        // LLM no longer returns trigger_phrases; caller populates them client-side
        let triggerPhrases = json["triggerPhrases"] as? [String]
            ?? json["trigger_phrases"] as? [String] ?? []

        var actions: [CommandAction] = []
        if let rawActions = json["actions"] as? [[String: Any]] {
            for (index, raw) in rawActions.enumerated() {
                guard let typeRaw = raw["type"] as? String,
                      let type = CommandActionType(rawValue: typeRaw),
                      let payloadValue = raw["payload"],
                      let payload = Self.payloadString(type: type, from: payloadValue) else {
                    continue
                }
                let order = raw["order"] as? Int ?? index

                let delayAfterMS = raw["delay_after_ms"] as? Int
                    ?? raw["delayAfterMS"] as? Int ?? 500
                let timeoutMS = raw["timeout_ms"] as? Int
                    ?? raw["timeoutMS"] as? Int ?? 5000
                let retryOnFailure = raw["retry_on_failure"] as? Bool
                    ?? raw["retryOnFailure"] as? Bool ?? false
                let maxRetries = raw["max_retries"] as? Int
                    ?? raw["maxRetries"] as? Int

                let completionCheck = parseCompletionCheck(from: raw)
                let fallbackAction = parseFallbackAction(from: raw)

                actions.append(
                    CommandAction(
                        type: type,
                        payload: payload,
                        order: order,
                        delayAfterMS: delayAfterMS,
                        timeoutMS: timeoutMS,
                        retryOnFailure: retryOnFailure,
                        maxRetries: maxRetries,
                        completionCheck: completionCheck,
                        fallbackAction: fallbackAction
                    )
                )
            }
        }
        let modeRaw = json["executionMode"] as? String
        let executionMode = resolveExecutionMode(modeRaw: modeRaw, actions: actions)

        // Parse explicit flag, then apply heuristic fallback
        let explicitFlag = json["requires_confirmation"] as? Bool
            ?? json["requiresConfirmation"] as? Bool
        let requiresConfirmation = explicitFlag ?? detectDangerousCommand(actions: actions)

        let shortSummary = parseSummary(from: json, triggerPhrases: triggerPhrases, name: name)
        let actionDesc = parseActionDescription(from: json, actions: actions)

        return Command(
            name: name,
            triggerPhrases: triggerPhrases,
            actions: actions,
            executionMode: executionMode,
            requiresConfirmation: requiresConfirmation,
            shortSummary: shortSummary,
            actionDescription: actionDesc
        )
    }

    // Extracts shortSummary from JSON, falling back to trigger phrase or name
    private static func parseSummary(
        from json: [String: Any],
        triggerPhrases: [String],
        name: String
    ) -> String {
        if let raw = json["shortSummary"] as? String, !raw.isEmpty {
            return CommandGeneratorPrompt.validateShortSummary(raw)
        }
        let fallback = triggerPhrases.first ?? name
        return CommandGeneratorPrompt.validateShortSummary(fallback)
    }

    // Extracts actionDescription from JSON, falling back to actions array
    private static func parseActionDescription(
        from json: [String: Any],
        actions: [CommandAction]
    ) -> String {
        if let raw = json["actionDescription"] as? String, !raw.isEmpty {
            return CommandGeneratorPrompt.validateActionDescription(raw)
        }
        guard !actions.isEmpty else { return "" }
        let bullets = actions
            .sorted { $0.order < $1.order }
            .map { "• \($0.type.displayName): \($0.payload)" }
        return "This command will:\n\(bullets.joined(separator: "\n"))"
    }

    // Strips markdown code fences that LLMs commonly wrap around JSON responses
    private static func stripCodeFences(_ text: String) -> String {
        var result = text
        if result.hasPrefix("```json") {
            result = String(result.dropFirst(7))
        } else if result.hasPrefix("```") {
            result = String(result.dropFirst(3))
        }
        if result.hasSuffix("```") {
            result = String(result.dropLast(3))
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Heuristic fallback when the LLM omits requires_confirmation
    private static func detectDangerousCommand(actions: [CommandAction]) -> Bool {
        let dangerousPatterns = [
            "rm ", "rm -", "rmdir", "delete", "trash", "empty",
            "shutdown", "restart", "reboot", "quit", "kill",
            "dd ", "diskutil", "format",
            "curl ", "wget ", "download", "upload",
            "mv ", "move", "overwrite",
            "sudo"
        ]
        for action in actions {
            let lower = action.payload.lowercased()
            if dangerousPatterns.contains(where: { lower.contains($0) }) {
                return true
            }
        }
        return false
    }

    private static func parseCompletionCheck(from raw: [String: Any]) -> CompletionCheck? {
        guard let check = raw["completion_check"] as? [String: Any]
                ?? raw["completionCheck"] as? [String: Any],
              let typeRaw = check["type"] as? String,
              let type = CompletionCheckType(rawValue: typeRaw),
              let value = check["value"] as? String else {
            return nil
        }
        return CompletionCheck(type: type, value: value)
    }

    private static func parseFallbackAction(from raw: [String: Any]) -> FallbackAction? {
        guard let fallback = raw["fallback_action"] as? [String: Any]
                ?? raw["fallbackAction"] as? [String: Any],
              let typeRaw = fallback["type"] as? String,
              let type = CommandActionType(rawValue: typeRaw),
              let payloadValue = fallback["payload"],
              let payload = Self.payloadString(type: type, from: payloadValue) else {
            return nil
        }
        return FallbackAction(type: type, payload: payload)
    }

    private static func payloadString(type: CommandActionType, from raw: Any) -> String? {
        if type == .shell {
            return CommandAction.decodePayload(from: raw)
        }
        return raw as? String
    }

    private static func resolveExecutionMode(
        modeRaw: String?,
        actions: [CommandAction]
    ) -> CommandExecutionMode {
        if let modeRaw, let explicit = CommandExecutionMode(rawValue: modeRaw) {
            return explicit
        }
        guard !actions.isEmpty else { return .appIntents }

        let hasShell = actions.contains { $0.type == .shell }
        let hasAppleScript = actions.contains { $0.type == .appleScript }
        if hasShell || hasAppleScript {
            return .mixed
        }
        return .appIntents
    }
}
