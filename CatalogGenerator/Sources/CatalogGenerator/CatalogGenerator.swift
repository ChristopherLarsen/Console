import ArgumentParser
import Foundation

@main
struct CatalogGenerator: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "catalog-generator",
        abstract: "Generates and manages the Console action catalog.",
        discussion: """
            Dev-only tool for discovering app capabilities, generating catalog \
            entries via LLM, validating entries, and reviewing them before \
            shipping with the main app.
            """,
        subcommands: [Discover.self, Generate.self, Validate.self, Review.self]
    )
}

// MARK: - Discover

struct Discover: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Scan installed apps and discover automation capabilities."
    )

    @Option(name: .shortAndLong, help: "Output path for discovered apps JSON.")
    var output: String = "discovered-apps.json"

    @Option(name: .long, help: "Discover a single app by path.")
    var appPath: String?

    @Flag(name: .shortAndLong, help: "Include verbose discovery logging.")
    var verbose: Bool = false

    @Flag(name: .long, help: "Only include apps with AppleScript or App Intents support.")
    var automationOnly: Bool = false

    func run() throws {
        let discoverer = CatalogDiscoverer(verbose: verbose)

        if let appPath {
            print("Discovering single app: \(appPath)")
            let appURL = URL(fileURLWithPath: appPath)
            let result = discoverer.discoverApp(appURL)
            let summary = discoverer.buildSummary(from: [result])
            try discoverer.writeSummary(summary, to: output)
            print("Wrote result to \(output)")
            return
        }

        let userApps = NSString(string: "~/Applications").expandingTildeInPath
        let paths = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            "/System/Library/CoreServices",
            userApps
        ]
        print("Scanning \(paths.count) app directories...")

        var apps = discoverer.discoverAllApps(at: paths)

        if automationOnly {
            apps = apps.filter { $0.hasAppleScriptDictionary || $0.hasAppIntentsMetadata }
        }

        let summary = discoverer.buildSummary(from: apps)
        try discoverer.writeSummary(summary, to: output)

        print("\nDiscovery complete:")
        print("  Total apps: \(summary.totalApps)")
        print("  With AppleScript dictionary: \(summary.appsWithAppleScript)")
        print("  With App Intents metadata: \(summary.appsWithAppIntents)")
        print("  Output: \(output)")
    }
}

// MARK: - Generate

struct Generate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Generate catalog entries from discovered app data using LLM."
    )

    @Option(name: .shortAndLong, help: "Path to discovered apps JSON input.")
    var input: String = "discovered-apps.json"

    @Option(name: .shortAndLong, help: "Output path for generated catalog.")
    var output: String = "ActionCatalog.json"

    @Option(name: .long, help: "Limit generation to a specific app bundle ID.")
    var appId: String?

    @Option(name: .long, help: "LLM provider: openai, claude, or gemini.")
    var provider: String = "claude"

    @Option(name: .long, help: "API key for the LLM provider.")
    var apiKey: String?

    @Option(name: .long, help: "Model name override.")
    var model: String?

    @Option(name: .long, help: "Catalog version string.")
    var version: String = "1.1.0"

    @Flag(name: .shortAndLong, help: "Verbose output.")
    var verbose: Bool = false

    @Flag(name: .long, help: "Skip apps that fail and continue batch.")
    var continueOnError: Bool = false

    func run() async throws {
        guard let key = apiKey ?? ProcessInfo.processInfo.environment["LLM_API_KEY"] else {
            print("Error: Provide --api-key or set LLM_API_KEY environment variable.")
            throw ExitCode.failure
        }

        let llmConfig = resolveLLMConfig(key: key)
        print("Generating catalog entries...")
        print("  Provider: \(provider) (\(llmConfig.model))")
        print("  Input: \(input)")
        print("  Output: \(output)")

        let inputURL = URL(fileURLWithPath: input)
        let data = try Data(contentsOf: inputURL)
        let summary = try JSONDecoder().decode(DiscoverySummary.self, from: data)

        var apps = summary.apps.filter { $0.hasAppleScriptDictionary || $0.hasAppIntentsMetadata }

        if let appId {
            apps = apps.filter { $0.bundleID == appId }
            if apps.isEmpty {
                print("Error: No app found with bundle ID '\(appId)'")
                throw ExitCode.failure
            }
        }

        print("  Apps to process: \(apps.count)")

        let generator = LLMCatalogGenerator(config: llmConfig, verbose: verbose)
        let result = await generator.generateBatch(from: apps, continueOnError: continueOnError)

        var catalog = generator.assembleCatalog(from: result.succeeded, version: version)

        // Never clobber the committed catalog with a partial run: merge this
        // run's entries into the existing output, replacing only the apps that
        // were regenerated. Write to a fresh path to rebuild from scratch.
        if let existing = generator.existingCatalog(at: output) {
            catalog = generator.merging(catalog, into: existing)
            let retained = (catalog["apps"] as? [[String: Any]])?.count ?? 0
            print("  Merged into existing catalog: \(result.succeeded.count) regenerated, \(max(0, retained - result.succeeded.count)) retained")
        }
        try generator.writeCatalog(catalog, to: output)

        print("\nGeneration complete:")
        print("  Succeeded: \(result.succeeded.count)")
        print("  Failed: \(result.failed.count)")
        print("  Success rate: \(String(format: "%.0f%%", result.successRate * 100))")
        print("  Output: \(output)")

        if !result.failed.isEmpty {
            print("\nFailed apps:")
            for (name, error) in result.failed {
                print("  ✗ \(name): \(error.localizedDescription)")
            }
        }
    }

    private func resolveLLMConfig(key: String) -> LLMConfig {
        switch provider.lowercased() {
        case "openai":
            return .openAI(apiKey: key, model: model ?? "gpt-4o")
        case "gemini":
            return .gemini(apiKey: key, model: model ?? "gemini-2.0-flash")
        default:
            return .claude(apiKey: key, model: model ?? "claude-sonnet-4-20250514")
        }
    }
}

// MARK: - Validate

struct Validate: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Validate catalog entries for correctness and safety."
    )

    @Argument(help: "Path to the catalog JSON to validate.")
    var catalogPath: String = "ActionCatalog.json"

    @Flag(name: .shortAndLong, help: "Run extended validation including timing checks.")
    var extended: Bool = false

    func run() throws {
        print("Validating catalog at: \(catalogPath)")
        if extended {
            print("  Running extended validation (timing + execution tests)")
        }
        print("Validation not yet implemented (Phase 7).")
    }
}

// MARK: - Review

struct Review: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Interactive review of generated catalog entries."
    )

    @Argument(help: "Path to the catalog JSON to review.")
    var catalogPath: String = "ActionCatalog.json"

    func run() throws {
        print("Opening catalog for review: \(catalogPath)")
        print("Review not yet implemented (Phase 8).")
    }
}
