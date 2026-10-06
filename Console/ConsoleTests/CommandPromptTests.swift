import XCTest
import SwiftData
@testable import Console

@MainActor
final class CommandPromptTests: XCTestCase {

    func testHintUsesTheFirstTwoNonEmptyLines() {
        let prompt = "\n  Look at the diff.  \n\nThen summarize the risk.\nIgnore the third line."
        XCTAssertEqual(
            CommandPromptText.hint(from: prompt),
            "Look at the diff.\nThen summarize the risk."
        )
    }

    func testCommandPromptKeepsPunctuationAndDropsControlCharacters() {
        let cleaned = InputSanitizer.commandPrompt("Fix `main`.\n\u{0007}Keep this.")
        XCTAssertEqual(cleaned, "Fix `main`.\nKeep this.")
    }

    func testLoadDropsLegacyCommandsAndKeepsConsoleAndPromptCommands() throws {
        let container = try ModelContainer(
            for: Schema([Command.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        context.insert(Command(
            name: "Open Browser",
            actions: [CommandAction(type: .appIntent, payload: "openApplication:Safari", order: 0)]
        ))
        context.insert(Command(
            name: "Old script",
            actions: [CommandAction(type: .appleScript, payload: "tell application \"Finder\" to activate", order: 0)]
        ))
        context.insert(Command(
            name: "Review the diff",
            claudePrompt: "Read the diff.\nSummarize it."
        ))
        context.insert(Command(
            name: "Settings",
            actions: [CommandAction(type: .appIntent, payload: ConsoleAction.fishSettings.rawValue, order: 0)],
            isConsole: true
        ))
        try context.save()

        _ = StarterCommandsProvider.loadStarterCommands(into: context)

        let names = Set((try context.fetch(FetchDescriptor<Command>())).map(\.name))
        XCTAssertFalse(names.contains("Open Browser"))
        XCTAssertFalse(names.contains("Open Terminal"))
        XCTAssertFalse(names.contains("Open Finder"))
        XCTAssertFalse(names.contains("Show Desktop"))
        XCTAssertFalse(names.contains("New Finder Window"))
        XCTAssertFalse(names.contains("Old script"))
        XCTAssertTrue(names.contains("Review the diff"))
        XCTAssertTrue(names.contains("Settings"))
        XCTAssertTrue(names.contains("Note"))
    }

    func testPromptCommandUsesTheLauncherInsteadOfActions() async {
        let previous = UserDefaults.standard.object(forKey: "requireAuthorizationForAllCommands")
        UserDefaults.standard.set(false, forKey: "requireAuthorizationForAllCommands")
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: "requireAuthorizationForAllCommands")
            } else {
                UserDefaults.standard.removeObject(forKey: "requireAuthorizationForAllCommands")
            }
        }

        let actions = ActionCallSpy()
        let executor = LocalCommandExecutor(actionExecutor: actions, authorizer: AllowingAuthorizer())
        var launchedName: String?
        executor.promptLauncher = { command in
            launchedName = command.name
            return true
        }
        let command = Command(name: "Review the diff", claudePrompt: "Read the diff.")

        let run = await executor.execute(command)

        XCTAssertEqual(launchedName, "Review the diff")
        XCTAssertEqual(actions.calls, 0)
        XCTAssertTrue(run.result.overallSuccess)
    }
}

private final class ActionCallSpy: CommandActionExecuting {
    var calls = 0

    func execute(_ action: CommandAction) async throws -> String {
        calls += 1
        return "should not run"
    }
}

private final class AllowingAuthorizer: CommandAuthorizing {
    func requestAuthorization(for command: Command) async -> Bool { true }
}
