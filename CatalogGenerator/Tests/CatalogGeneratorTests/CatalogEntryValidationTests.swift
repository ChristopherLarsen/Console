import XCTest
@testable import CatalogGenerator

final class CatalogEntryValidationTests: XCTestCase {

    private func makeGenerator() -> LLMCatalogGenerator {
        LLMCatalogGenerator(config: .claude(apiKey: "test-key"), verbose: false)
    }

    /// A complete entry that satisfies the runtime ActionCatalog Codable schema.
    private func validEntry(bundleID: String = "com.example.app") -> [String: Any] {
        [
            "name": "Example",
            "bundleID": bundleID,
            "minMacOSVersion": "13.0",
            "appIntents": [] as [[String: Any]],
            "applescriptActions": [
                [
                    "functionName": "open_example",
                    "scriptTemplate": "tell application \"Example\" to activate",
                    "actionDescription": "Open Example",
                    "parameters": [] as [String],
                    "reliabilityScore": 0.95,
                    "avgExecutionTimeMS": 2000,
                ] as [String: Any]
            ],
            "shellCommands": [
                [
                    "name": "open_example_app",
                    "command": "open",
                    "argsTemplate": ["-a", "Example"],
                    "safetyCheck": NSNull(),
                    "commandDescription": "Open the Example app",
                ] as [String: Any]
            ],
            "commonPatterns": [
                ["userIntent": "open example", "exampleActions": ["open_example"]]
            ],
            "knownIssues": [] as [String],
            "timingHeuristics": ["launchDelay": 2000, "actionDelay": 1000],
        ] as [String: Any]
    }

    func testValidEntryPasses() throws {
        try makeGenerator().validateEntry(validEntry(), appName: "Example")
    }

    /// H47-F04: this entry passed the old validation (only functionName +
    /// scriptTemplate were checked) but fails the runtime decoder.
    func testActionMissingRuntimeRequiredFieldsIsRejected() {
        var entry = validEntry()
        var action = (entry["applescriptActions"] as! [[String: Any]])[0]
        action.removeValue(forKey: "actionDescription")
        action["avgExecutionTimeMS"] = "2000" // string instead of Int
        entry["applescriptActions"] = [action]
        XCTAssertThrowsError(
            try makeGenerator().validateEntry(entry, appName: "Example")
        ) { error in
            XCTAssertTrue("\(error)".contains("applescriptAction"))
        }
    }

    func testShellCommandMissingCommandDescriptionIsRejected() {
        var entry = validEntry()
        var command = (entry["shellCommands"] as! [[String: Any]])[0]
        command.removeValue(forKey: "commandDescription")
        entry["shellCommands"] = [command]
        XCTAssertThrowsError(
            try makeGenerator().validateEntry(entry, appName: "Example")
        )
    }

    func testIntentParameterMissingIsRequiredIsRejected() {
        var entry = validEntry()
        entry["appIntents"] = [
            [
                "intentName": "CreateNoteIntent",
                "intentDescription": "Creates a note",
                "parameters": [["name": "title", "type": "String"] as [String: Any]],
                "exampleUsage": "create a note",
                "reliabilityScore": 0.7,
                "avgExecutionTimeMS": 1500,
            ] as [String: Any]
        ]
        XCTAssertThrowsError(
            try makeGenerator().validateEntry(entry, appName: "Example")
        ) { error in
            XCTAssertTrue("\(error)".contains("isRequired"))
        }
    }

    func testTimingHeuristicsWithStringDelayIsRejected() {
        var entry = validEntry()
        entry["timingHeuristics"] = ["launchDelay": "2000", "actionDelay": 1000]
        XCTAssertThrowsError(
            try makeGenerator().validateEntry(entry, appName: "Example")
        )
    }
}

final class CatalogMergeTests: XCTestCase {

    private func entry(bundleID: String, name: String) -> [String: Any] {
        ["name": name, "bundleID": bundleID]
    }

    func testMergeRetainsAppsNotRegenerated() throws {
        let generator = LLMCatalogGenerator(config: .claude(apiKey: "test-key"))
        let base: [String: Any] = [
            "version": "1.1.0",
            "lastUpdated": "2026-01-01T00:00:00Z",
            "macOSVersions": ["15.0"],
            "apps": [
                entry(bundleID: "com.a", name: "A"),
                entry(bundleID: "com.b", name: "B"),
                entry(bundleID: "com.c", name: "C"),
            ],
        ]
        let run: [String: Any] = [
            "version": "1.1.0",
            "lastUpdated": "2026-02-01T00:00:00Z",
            "macOSVersions": ["15.0"],
            "apps": [entry(bundleID: "com.b", name: "B2")],
        ]

        let merged = generator.merging(run, into: base)
        let apps = try XCTUnwrap(merged["apps"] as? [[String: Any]])
        XCTAssertEqual(apps.count, 3, "partial run must not shrink the catalog")
        let ids = Set(apps.compactMap { $0["bundleID"] as? String })
        XCTAssertEqual(ids, ["com.a", "com.b", "com.c"])
        let regenerated = apps.first { ($0["bundleID"] as? String) == "com.b" }
        XCTAssertEqual(regenerated?["name"] as? String, "B2")
        XCTAssertEqual(merged["lastUpdated"] as? String, "2026-02-01T00:00:00Z")
    }

    func testExistingCatalogLoadRequiresAppsArray() throws {
        let generator = LLMCatalogGenerator(config: .claude(apiKey: "test-key"))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let path = directory.appendingPathComponent("ActionCatalog.json").path
        XCTAssertNil(generator.existingCatalog(at: path), "missing file → nil")

        try Data("{\"apps\": []}".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertNotNil(generator.existingCatalog(at: path))
    }
}

final class AppIntentsMetadataTests: XCTestCase {

    func testMetadataAppintentsDirectoryIsDetected() throws {
        let appURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fake.app-\(UUID().uuidString)", isDirectory: true)
        let metadataDir = appURL.appendingPathComponent("Contents/Resources/Metadata.appintents", isDirectory: true)
        try FileManager.default.createDirectory(at: metadataDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appURL) }

        let actions = """
        {"actions": {"CreateNoteAction": {"assistantDefinedSchemas": []}}}
        """
        try Data(actions.utf8).write(to: metadataDir.appendingPathComponent("extract.actionsdata"))

        let discoverer = CatalogDiscoverer()
        let data = discoverer.discoverApp(appURL)
        XCTAssertTrue(data.hasAppIntentsMetadata, "Metadata.appintents directory must count as App Intents metadata")
        XCTAssertTrue(data.appIntentsMetadataKeys.contains("actions"))
    }

    func testAppWithoutMetadataIsNotFalsePositive() throws {
        let appURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bare.app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appURL) }

        let data = CatalogDiscoverer().discoverApp(appURL)
        XCTAssertFalse(data.hasAppIntentsMetadata)
    }
}