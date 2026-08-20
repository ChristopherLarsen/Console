import Foundation

enum Capability: String, CaseIterable {
    case chat
    case vision
    case functionCalling
    case jsonMode
    case streaming

    var displayName: String {
        switch self {
        case .chat: return "Chat"
        case .vision: return "Vision"
        case .functionCalling: return "Function Calling"
        case .jsonMode: return "JSON Mode"
        case .streaming: return "Streaming"
        }
    }
}

struct Pricing: Sendable {
    let inputPer1MTokens: Decimal
    let outputPer1MTokens: Decimal

    var summary: String {
        "$\(inputPer1MTokens)/\(outputPer1MTokens) per 1M tokens (in/out)"
    }
}

struct ModelInfo: Sendable {
    let id: String
    let capabilities: [Capability]
    let contextWindow: Int
    let pricing: Pricing?
    let documentationURL: URL?

    // Formatted context window for display (e.g. "128K")
    var contextLabel: String {
        if contextWindow >= 1_000_000 {
            return "\(contextWindow / 1_000_000)M"
        }
        return "\(contextWindow / 1_000)K"
    }

    var tooltip: String {
        var parts: [String] = []
        parts.append("Context: \(contextLabel)")
        let caps = capabilities.map(\.displayName).joined(separator: ", ")
        if !caps.isEmpty { parts.append(caps) }
        if let pricing { parts.append(pricing.summary) }
        return parts.joined(separator: " · ")
    }

    // Static metadata for well-known models
    static let catalog: [String: ModelInfo] = {
        var map: [String: ModelInfo] = [:]

        // OpenAI
        let openAIDocs = URL(string: "https://platform.openai.com/docs/models")
        let fullCaps: [Capability] = [.chat, .vision, .functionCalling, .jsonMode, .streaming]
        let chatCaps: [Capability] = [.chat, .functionCalling, .jsonMode, .streaming]

        map["gpt-4o"] = ModelInfo(
            id: "gpt-4o", capabilities: fullCaps, contextWindow: 128_000,
            pricing: Pricing(inputPer1MTokens: 2.50, outputPer1MTokens: 10.00),
            documentationURL: openAIDocs
        )
        map["gpt-4o-mini"] = ModelInfo(
            id: "gpt-4o-mini", capabilities: fullCaps, contextWindow: 128_000,
            pricing: Pricing(inputPer1MTokens: 0.15, outputPer1MTokens: 0.60),
            documentationURL: openAIDocs
        )
        map["o1"] = ModelInfo(
            id: "o1", capabilities: chatCaps, contextWindow: 200_000,
            pricing: Pricing(inputPer1MTokens: 15.00, outputPer1MTokens: 60.00),
            documentationURL: openAIDocs
        )
        map["o1-mini"] = ModelInfo(
            id: "o1-mini", capabilities: chatCaps, contextWindow: 128_000,
            pricing: Pricing(inputPer1MTokens: 3.00, outputPer1MTokens: 12.00),
            documentationURL: openAIDocs
        )
        map["o3-mini"] = ModelInfo(
            id: "o3-mini", capabilities: chatCaps, contextWindow: 200_000,
            pricing: Pricing(inputPer1MTokens: 1.10, outputPer1MTokens: 4.40),
            documentationURL: openAIDocs
        )

        // Claude
        let claudeDocs = URL(string: "https://docs.anthropic.com/en/docs/about-claude/models")
        let claudeCaps: [Capability] = [.chat, .vision, .functionCalling, .streaming]

        map["claude-opus-4-6"] = ModelInfo(
            id: "claude-opus-4-6", capabilities: claudeCaps, contextWindow: 200_000,
            pricing: Pricing(inputPer1MTokens: 5.00, outputPer1MTokens: 25.00),
            documentationURL: claudeDocs
        )
        map["claude-sonnet-4-5-20250929"] = ModelInfo(
            id: "claude-sonnet-4-5-20250929", capabilities: claudeCaps, contextWindow: 200_000,
            pricing: Pricing(inputPer1MTokens: 3.00, outputPer1MTokens: 15.00),
            documentationURL: claudeDocs
        )
        map["claude-haiku-4-5-20251001"] = ModelInfo(
            id: "claude-haiku-4-5-20251001", capabilities: claudeCaps, contextWindow: 200_000,
            pricing: Pricing(inputPer1MTokens: 1.00, outputPer1MTokens: 5.00),
            documentationURL: claudeDocs
        )
        map["claude-opus-4-20250514"] = ModelInfo(
            id: "claude-opus-4-20250514", capabilities: claudeCaps, contextWindow: 200_000,
            pricing: Pricing(inputPer1MTokens: 15.00, outputPer1MTokens: 75.00),
            documentationURL: claudeDocs
        )
        map["claude-sonnet-4-20250514"] = ModelInfo(
            id: "claude-sonnet-4-20250514", capabilities: claudeCaps, contextWindow: 200_000,
            pricing: Pricing(inputPer1MTokens: 3.00, outputPer1MTokens: 15.00),
            documentationURL: claudeDocs
        )
        map["claude-3-5-sonnet-20241022"] = ModelInfo(
            id: "claude-3-5-sonnet-20241022", capabilities: claudeCaps, contextWindow: 200_000,
            pricing: Pricing(inputPer1MTokens: 3.00, outputPer1MTokens: 15.00),
            documentationURL: claudeDocs
        )
        map["claude-3-5-haiku-20241022"] = ModelInfo(
            id: "claude-3-5-haiku-20241022", capabilities: claudeCaps, contextWindow: 200_000,
            pricing: Pricing(inputPer1MTokens: 0.80, outputPer1MTokens: 4.00),
            documentationURL: claudeDocs
        )

        // Gemini
        let geminiDocs = URL(string: "https://ai.google.dev/gemini-api/docs/models")
        let geminiCaps: [Capability] = [.chat, .vision, .functionCalling, .jsonMode, .streaming]

        map["gemini-2.0-flash"] = ModelInfo(
            id: "gemini-2.0-flash", capabilities: geminiCaps, contextWindow: 1_048_576,
            pricing: Pricing(inputPer1MTokens: 0.10, outputPer1MTokens: 0.40),
            documentationURL: geminiDocs
        )
        map["gemini-1.5-pro"] = ModelInfo(
            id: "gemini-1.5-pro", capabilities: geminiCaps, contextWindow: 2_097_152,
            pricing: Pricing(inputPer1MTokens: 1.25, outputPer1MTokens: 5.00),
            documentationURL: geminiDocs
        )
        map["gemini-1.5-flash"] = ModelInfo(
            id: "gemini-1.5-flash", capabilities: geminiCaps, contextWindow: 1_048_576,
            pricing: Pricing(inputPer1MTokens: 0.075, outputPer1MTokens: 0.30),
            documentationURL: geminiDocs
        )

        // Grok
        let grokDocs = URL(string: "https://docs.x.ai/docs")
        let grokCaps: [Capability] = [.chat, .functionCalling, .streaming]

        map["grok-2-latest"] = ModelInfo(
            id: "grok-2-latest", capabilities: grokCaps, contextWindow: 131_072,
            pricing: Pricing(inputPer1MTokens: 2.00, outputPer1MTokens: 10.00),
            documentationURL: grokDocs
        )
        map["grok-2-1212"] = ModelInfo(
            id: "grok-2-1212", capabilities: grokCaps, contextWindow: 131_072,
            pricing: Pricing(inputPer1MTokens: 2.00, outputPer1MTokens: 10.00),
            documentationURL: grokDocs
        )

        return map
    }()

    static func info(for modelID: String) -> ModelInfo? {
        catalog[modelID]
    }
}
