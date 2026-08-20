import Foundation

// Anthropic has no public model listing API — returns a curated static list.
// Last updated: 2026-02-11. Check https://docs.anthropic.com/en/docs/about-claude/models
struct ClaudeModelFetcher: ModelFetcher {
    let apiKey: String

    private static let knownModels: [AvailableModel] = [
        AvailableModel(id: "claude-opus-4-6", displayName: "Claude Opus 4.6"),
        AvailableModel(id: "claude-sonnet-4-5-20250929", displayName: "Claude Sonnet 4.5 (Sep 2025)"),
        AvailableModel(id: "claude-haiku-4-5-20251001", displayName: "Claude Haiku 4.5 (Oct 2025)"),
        AvailableModel(id: "claude-opus-4-20250514", displayName: "Claude Opus 4 (May 2025)"),
        AvailableModel(id: "claude-sonnet-4-20250514", displayName: "Claude Sonnet 4 (May 2025)"),
        AvailableModel(id: "claude-3-5-sonnet-20241022", displayName: "Claude 3.5 Sonnet (Oct 2024)"),
        AvailableModel(id: "claude-3-5-haiku-20241022", displayName: "Claude 3.5 Haiku (Oct 2024)"),
    ]

    init(apiKey: String, config: AIProviderConfig) {
        self.apiKey = apiKey
    }

    func fetchAvailableModels() async throws -> [AvailableModel] {
        Self.knownModels
    }
}
