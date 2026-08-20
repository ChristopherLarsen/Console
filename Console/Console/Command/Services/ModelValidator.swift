import Foundation

enum ModelValidationResult: Equatable {
    case valid
    case warning(String)
    case invalid(String)

    var isAcceptable: Bool {
        switch self {
        case .valid, .warning: return true
        case .invalid: return false
        }
    }
}

enum ModelValidator {
    static func validate(_ modelName: String, for provider: AIProvider) -> ModelValidationResult {
        guard !modelName.isEmpty else {
            return .invalid("No model selected")
        }

        let knownIDs = knownModelIDs(for: provider)

        if knownIDs.contains(modelName) {
            return .valid
        }

        // Check for close matches (typos, wrong casing)
        let lowered = modelName.lowercased()
        if knownIDs.contains(where: { $0.lowercased() == lowered }) {
            return .warning("Check model name casing")
        }

        // Prefix match suggests a valid but unrecognized variant
        let prefixes = knownPrefixes(for: provider)
        if prefixes.contains(where: { lowered.hasPrefix($0) }) {
            return .warning("Unrecognized variant — verify the model name is correct")
        }

        return .warning("Custom model — ensure this name matches your provider's documentation")
    }

    // Known model IDs per provider
    private static func knownModelIDs(for provider: AIProvider) -> Set<String> {
        switch provider {
        case .openAI:
            return [
                "gpt-4o", "gpt-4o-mini", "gpt-4-turbo", "gpt-4",
                "o1", "o1-mini", "o1-preview", "o3", "o3-mini",
            ]
        case .claude:
            return [
                "claude-opus-4-6",
                "claude-sonnet-4-5-20250929", "claude-haiku-4-5-20251001",
                "claude-opus-4-20250514", "claude-sonnet-4-20250514",
                "claude-3-5-sonnet-20241022", "claude-3-5-haiku-20241022",
            ]
        case .gemini:
            return [
                "gemini-2.0-flash", "gemini-2.0-flash-lite",
                "gemini-1.5-pro", "gemini-1.5-flash", "gemini-1.5-flash-8b",
            ]
        case .grok:
            return ["grok-2-latest", "grok-2-1212", "grok-beta"]
        case .lmStudio:
            return []
        case .none:
            return []
        }
    }

    // Expected prefixes for each provider's model naming scheme
    private static func knownPrefixes(for provider: AIProvider) -> [String] {
        switch provider {
        case .openAI: return ["gpt-", "o1", "o3", "o4"]
        case .claude: return ["claude-"]
        case .gemini: return ["gemini-"]
        case .grok: return ["grok-"]
        case .lmStudio: return []
        case .none: return []
        }
    }
}
