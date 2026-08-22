import XCTest
@testable import Console

/// Verifies the helper binary and plugin resources are embedded and signed.
final class SessionsPackagingTests: XCTestCase {

    private var appBundle: URL { Bundle.main.bundleURL }

    func testHelperIsEmbeddedInContentsHelpers() {
        let helperPath = appBundle
            .appendingPathComponent("Contents/Helpers/ConsoleTermBridge").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: helperPath))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helperPath))
    }

    func testHelperRunsAndReportsNoArgumentsSilently() throws {
        let helperPath = appBundle
            .appendingPathComponent("Contents/Helpers/ConsoleTermBridge").path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: helperPath)
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, EXIT_SUCCESS, "bare invocation exits cleanly")
        XCTAssertEqual(stdoutPipe.fileHandleForReading.readDataToEndOfFile().count, 0)
    }

    func testHelperCodeSignatureIsValid() throws {
        let helperPath = appBundle
            .appendingPathComponent("Contents/Helpers/ConsoleTermBridge").path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--strict", helperPath]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0, "embedded helper must be signed")
    }

    func testPluginResourcesAreBundled() throws {
        for resource in [
            ConsoleClaudePluginAssembler.manifestResource,
            ConsoleClaudePluginAssembler.hooksResource,
            ConsoleClaudePluginAssembler.mcpResource,
        ] {
            XCTAssertNotNil(
                Bundle.main.url(forResource: resource, withExtension: nil),
                "missing bundled plugin resource \(resource)"
            )
        }
    }

    func testAssembledPluginHasCanonicalLayout() throws {
        let assembler = ConsoleClaudePluginAssembler(bundle: .main)
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-assembly-\(UUID().uuidString)", isDirectory: true)

        let pluginRoot = try assembler.materialize(in: base)

        for relative in [".claude-plugin/plugin.json", "hooks/hooks.json", ".mcp.json"] {
            let path = pluginRoot.appendingPathComponent(relative).path
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), "missing \(relative)")
        }

        // Manifest names the plugin consistently with preapproved tool names.
        let manifestData = try Data(contentsOf: pluginRoot.appendingPathComponent(".claude-plugin/plugin.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        XCTAssertEqual(manifest["name"] as? String, ConsoleClaudePluginAssembler.pluginName)

        // Hooks invoke the helper through environment variables.
        let hooksData = try Data(contentsOf: pluginRoot.appendingPathComponent("hooks/hooks.json"))
        let hooksJSON = String(decoding: hooksData, as: UTF8.self)
        XCTAssertTrue(hooksJSON.contains("CONSOLE_TERM_BRIDGE_HELPER"))
        XCTAssertTrue(hooksJSON.contains("hook SessionStart"))
        XCTAssertTrue(hooksJSON.contains("AskUserQuestion"), "user-question PreToolUse matcher present")
        XCTAssertFalse(hooksJSON.contains("async\" : false"))

        // MCP config points at the same helper.
        let mcpData = try Data(contentsOf: pluginRoot.appendingPathComponent(".mcp.json"))
        let mcp = try XCTUnwrap(JSONSerialization.jsonObject(with: mcpData) as? [String: Any])
        let servers = try XCTUnwrap(mcp["mcpServers"] as? [String: Any])
        let console = try XCTUnwrap(servers["console"] as? [String: Any])
        XCTAssertTrue((console["command"] as? String)?.contains("CONSOLE_TERM_BRIDGE_HELPER") == true)
    }

    func testAllowedToolNamesAreExactQualifiedNames() {
        XCTAssertEqual(
            Set(ConsoleClaudePluginAssembler.allowedToolNames),
            [
                "mcp__plugin_console-bridge_console__report_attention",
                "mcp__plugin_console-bridge_console__link_artifact",
                "mcp__plugin_console-bridge_console__report_completion",
            ]
        )
        XCTAssertEqual(ConsoleClaudePluginAssembler.allowedToolNames.count, 3)
        XCTAssertFalse(
            ConsoleClaudePluginAssembler.allowedToolNames.contains(where: { $0.contains("*") }),
            "no wildcards"
        )
    }

    @MainActor
    func testLaunchArgumentsCarryIdentityNamePluginAndPreapprovals() {
        let args = SessionStore.launchArguments(
            claudeSessionID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            name: "My Task",
            pluginDirectory: "/tmp/plugins/console-bridge"
        )

        XCTAssertTrue(args.elementsEqual([
            "--session-id", "11111111-2222-3333-4444-555555555555",
            "--name", "My Task",
            "--plugin-dir", "/tmp/plugins/console-bridge",
            "--allowedTools",
            "mcp__plugin_console-bridge_console__report_attention",
            "mcp__plugin_console-bridge_console__link_artifact",
            "mcp__plugin_console-bridge_console__report_completion",
        ]) { $0 == $1 })
    }
}
