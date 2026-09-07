import XCTest
import SwiftData
@testable import Console

@MainActor
final class CommandImportExportTests: XCTestCase {

    private var container: ModelContainer!
    private var modelContext: ModelContext!
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        let schema = Schema([Command.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: [config])
        modelContext = ModelContext(container)
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommandImportExportTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        modelContext = nil
        container = nil
        super.tearDown()
    }

    // MARK: - H06-F01: action execution fields survive the developer round-trip

    func testToJSONIncludesActionExecutionFields() throws {
        let command = makeFullyConfiguredCommand()

        let json = CommandExporter.toJSON(command)
        let actions = try XCTUnwrap(json["actions"] as? [[String: Any]])
        XCTAssertEqual(actions.count, 1)
        let action = try XCTUnwrap(actions.first)

        XCTAssertEqual(action["delayAfterMS"] as? Int, 2500)
        XCTAssertEqual(action["timeoutMS"] as? Int, 12345)
        XCTAssertEqual(action["retryOnFailure"] as? Bool, true)
        XCTAssertEqual(action["maxRetries"] as? Int, 3)

        let completionCheck = try XCTUnwrap(action["completionCheck"] as? [String: Any])
        XCTAssertEqual(completionCheck["type"] as? String, "windowTitle")
        XCTAssertEqual(completionCheck["value"] as? String, "Synthetic Round Trip Window")

        let fallback = try XCTUnwrap(action["fallbackAction"] as? [String: Any])
        XCTAssertEqual(fallback["type"] as? String, "appleScript")
        XCTAssertEqual(fallback["payload"] as? String, "return \"fallback\"")
    }

    func testFullJSONFileRoundTripPreservesActionExecutionFields() throws {
        let command = makeFullyConfiguredCommand()
        modelContext.insert(command)
        try modelContext.save()

        let payload = [CommandExporter.toFullJSON(command)]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let fileURL = tempDirectory.appendingPathComponent("developer_commands.json")
        try data.write(to: fileURL, options: .atomic)

        try CommandImporter.importAllFromFile(into: modelContext, fileURL: fileURL)

        let fetched = try modelContext.fetch(FetchDescriptor<Command>())
        XCTAssertEqual(fetched.count, 1)
        let imported = try XCTUnwrap(fetched.first)
        XCTAssertEqual(imported.actions.count, 1)

        let original = command.actions[0]
        let action = imported.actions[0]
        XCTAssertEqual(action.type, original.type)
        XCTAssertEqual(action.payload, original.payload)
        XCTAssertEqual(action.order, original.order)
        XCTAssertEqual(action.delayAfterMS, 2500)
        XCTAssertEqual(action.timeoutMS, 12345)
        XCTAssertEqual(action.retryOnFailure, true)
        XCTAssertEqual(action.maxRetries, 3)
        XCTAssertEqual(action.completionCheck, original.completionCheck)
        XCTAssertEqual(action.fallbackAction, original.fallbackAction)
    }

    // MARK: - H06-F03: import must not wipe the store unless something imports

    func testImportEmptyArrayLeavesExistingCommandsIntact() throws {
        try seedStoredCommand()

        let fileURL = tempDirectory.appendingPathComponent("developer_commands.json")
        try "[]".write(to: fileURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try CommandImporter.importAllFromFile(into: modelContext, fileURL: fileURL)
        ) { error in
            XCTAssertEqual(error as? CommandImporter.ImportError, .noImportableCommands)
        }

        let fetched = try modelContext.fetch(FetchDescriptor<Command>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.name, "Synthetic Seed Command")
    }

    func testImportWithNoValidEntriesLeavesExistingCommandsIntact() throws {
        try seedStoredCommand()

        let partial: [[String: Any]] = [
            ["actions": [["type": "appleScript", "payload": "return \"ok\""]]],
            ["name": "No Actions"],
            ["name": "Bad Actions", "actions": [["type": "appleScript"]]]
        ]
        let fileURL = tempDirectory.appendingPathComponent("developer_commands.json")
        try JSONSerialization.data(withJSONObject: partial).write(to: fileURL, options: .atomic)

        XCTAssertThrowsError(
            try CommandImporter.importAllFromFile(into: modelContext, fileURL: fileURL)
        ) { error in
            XCTAssertEqual(error as? CommandImporter.ImportError, .noImportableCommands)
        }

        let fetched = try modelContext.fetch(FetchDescriptor<Command>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.name, "Synthetic Seed Command")
    }

    func testImportWithValidEntryReplacesStore() throws {
        try seedStoredCommand()

        let payload: [[String: Any]] = [
            [
                "name": "Synthetic Imported Command",
                "triggerPhrases": ["synthetic imported"],
                "executionMode": "appleScript",
                "actions": [["type": "appleScript", "payload": "return \"ok\"", "order": 0]]
            ]
        ]
        let fileURL = tempDirectory.appendingPathComponent("developer_commands.json")
        try JSONSerialization.data(withJSONObject: payload).write(to: fileURL, options: .atomic)

        let count = try CommandImporter.importAllFromFile(into: modelContext, fileURL: fileURL)

        XCTAssertEqual(count, 1)
        let fetched = try modelContext.fetch(FetchDescriptor<Command>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.name, "Synthetic Imported Command")
    }

    // MARK: - Helpers

    private func seedStoredCommand() throws {
        let seed = Command(
            name: "Synthetic Seed Command",
            triggerPhrases: ["synthetic seed"],
            actions: [CommandAction(type: .appleScript, payload: "return \"ok\"", order: 0)]
        )
        modelContext.insert(seed)
        try modelContext.save()
    }

    private func makeFullyConfiguredCommand() -> Command {
        Command(
            name: "Synthetic Round Trip Source",
            commandDescription: "Synthetic description for import/export round trip",
            triggerPhrases: ["synthetic round trip"],
            actions: [
                CommandAction(
                    type: .appleScript,
                    payload: "return \"ok\"",
                    order: 2,
                    delayAfterMS: 2500,
                    timeoutMS: 12345,
                    retryOnFailure: true,
                    maxRetries: 3,
                    completionCheck: .windowTitle("Synthetic Round Trip Window"),
                    fallbackAction: FallbackAction(type: .appleScript, payload: "return \"fallback\"")
                )
            ],
            executionMode: .appleScript
        )
    }
}

// MARK: - H07-F01: starter seed path

@MainActor
final class StarterCommandsProviderTests: XCTestCase {

    func testLoadStarterCommandsSeedsFreshStore() throws {
        let schema = Schema([Command.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)

        let loaded = StarterCommandsProvider.loadStarterCommands(into: context)

        XCTAssertGreaterThan(loaded, 0)
        let fetched = try context.fetch(FetchDescriptor<Command>())
        let names = Set(fetched.map(\.name))
        XCTAssertTrue(names.contains("Open Terminal"))
        XCTAssertTrue(names.contains("Open Browser"))
        XCTAssertTrue(names.contains("Stop Listening"))

        // Idempotent: a second pass must not duplicate starters.
        let reloaded = StarterCommandsProvider.loadStarterCommands(into: context)
        XCTAssertEqual(reloaded, 0)
        let refetched = try context.fetch(FetchDescriptor<Command>())
        XCTAssertEqual(refetched.count, fetched.count)
    }
}
