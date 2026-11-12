import Foundation

/// Test seam for optional plugin assembly. Production uses
/// `ConsoleClaudePluginAssembler`; tests inject failures without touching
/// bundled resources.
protocol ConsoleClaudePluginAssembling {
    func materialize(in baseDirectory: URL) throws -> URL
}

/// Assembles the session-scoped Claude plugin layout from the bundled
/// ConsoleClaudePlugin resources into the protected ephemeral directory.
struct ConsoleClaudePluginAssembler: ConsoleClaudePluginAssembling {
    enum AssemblyError: Error, Equatable {
        case missingResource(String)
    }

    static let pluginName = "console-bridge"
    static let manifestResource = "ConsoleClaudePlugin.plugin.json"
    static let hooksResource = "ConsoleClaudePlugin.hooks.json"
    static let mcpResource = "ConsoleClaudePlugin.mcp.json"
    static let orchestratorRunSkillResource = "ConsoleClaudePlugin.skill.orchestrator-run.md"
    static let orchestratorDiscoverSkillResource = "ConsoleClaudePlugin.skill.orchestrator-discover.md"
    static let orchestratorRunCommandResource = "ConsoleClaudePlugin.command.orchestrator-run.md"

    /// Qualified MCP tool names preapproved through Claude launch arguments.
    /// Only these exact names; never a wildcard.
    static var allowedToolNames: [String] {
        let prefix = "mcp__plugin_\(pluginName)_console__"
        return [
            "\(prefix)report_attention",
            "\(prefix)link_artifact",
            "\(prefix)report_completion",
            "\(prefix)list_console_sessions",
            "\(prefix)create_console_session",
            "\(prefix)close_console_session",
            "\(prefix)prompt_console_session",
            "\(prefix)read_console_session_output",
            "\(prefix)cancel_console_directive",
            "\(prefix)get_home_board",
        ]
    }

    let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    /// Writes the canonical plugin layout:
    ///
    ///     <base>/console-bridge/
    ///     ├── .claude-plugin/plugin.json
    ///     ├── hooks/hooks.json
    ///     ├── .mcp.json
    ///     ├── skills/orchestrator-run/SKILL.md
    ///     ├── skills/orchestrator-discover/SKILL.md
    ///     └── commands/orchestrator-run.md
    ///
    /// Returns the plugin root to pass to `--plugin-dir`.
    @discardableResult
    func materialize(in baseDirectory: URL) throws -> URL {
        let pluginRoot = baseDirectory
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent(Self.pluginName, isDirectory: true)

        let fm = FileManager.default
        try fm.createDirectory(
            at: pluginRoot.appendingPathComponent(".claude-plugin", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fm.createDirectory(
            at: pluginRoot.appendingPathComponent("hooks", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fm.createDirectory(
            at: pluginRoot.appendingPathComponent("skills/orchestrator-run", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fm.createDirectory(
            at: pluginRoot.appendingPathComponent("skills/orchestrator-discover", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fm.createDirectory(
            at: pluginRoot.appendingPathComponent("commands", isDirectory: true),
            withIntermediateDirectories: true
        )

        try write(Self.manifestResource, to: pluginRoot.appendingPathComponent(".claude-plugin/plugin.json"))
        try write(Self.hooksResource, to: pluginRoot.appendingPathComponent("hooks/hooks.json"))
        try write(Self.mcpResource, to: pluginRoot.appendingPathComponent(".mcp.json"))
        try write(Self.orchestratorRunSkillResource, to: pluginRoot.appendingPathComponent("skills/orchestrator-run/SKILL.md"))
        try write(Self.orchestratorDiscoverSkillResource, to: pluginRoot.appendingPathComponent("skills/orchestrator-discover/SKILL.md"))
        try write(Self.orchestratorRunCommandResource, to: pluginRoot.appendingPathComponent("commands/orchestrator-run.md"))
        return pluginRoot
    }

    private func resourceData(_ name: String) throws -> Data {
        guard let url = bundle.url(forResource: name, withExtension: nil),
              let data = try? Data(contentsOf: url) else {
            throw AssemblyError.missingResource(name)
        }
        return data
    }

    private func write(_ resourceName: String, to destination: URL) throws {
        try resourceData(resourceName).write(to: destination, options: .atomic)
    }
}
