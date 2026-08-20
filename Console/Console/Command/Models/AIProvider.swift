import Foundation

enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case openAI
    case claude
    case gemini
    case grok
    case lmStudio
    case none

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .grok: return "Grok"
        case .lmStudio: return "LM Studio"
        case .none: return "Select Provider"
        }
    }

    var documentationURL: URL? {
        switch self {
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")
        case .claude: return URL(string: "https://console.anthropic.com/settings/keys")
        case .gemini: return URL(string: "https://aistudio.google.com/app/apikey")
        case .grok: return URL(string: "https://console.x.ai")
        case .lmStudio: return URL(string: "https://lmstudio.ai/docs/developer/rest")
        case .none: return nil
        }
    }

    /// Whether this provider can operate without a stored API key (local servers).
    var requiresAPIKey: Bool {
        switch self {
        case .lmStudio: return false
        case .openAI, .claude, .gemini, .grok, .none: return true
        }
    }

    var defaultModelID: String {
        AIProviderConfig.defaultConfigs[self]?.modelName ?? ""
    }
}
