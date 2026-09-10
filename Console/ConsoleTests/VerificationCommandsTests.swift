import XCTest
import SwiftData
@testable import Console

final class VerificationCommandsTests: XCTestCase {

    // MARK: - H07-F02: catalog prompt includes executable patterns

    func testFormattedForPromptIncludesExecutableTemplates() {
        let catalog = ActionCatalog(
            version: "1",
            lastUpdated: Date(),
            macOSVersions: ["26"],
            apps: [
                AppCatalogEntry(
                    name: "Music",
                    bundleID: "com.apple.Music",
                    minMacOSVersion: "14.0",
                    appIntents: [],
                    applescriptActions: [
                        AppleScriptCatalogEntry(
                            functionName: "playPause",
                            scriptTemplate: "tell application \"Music\" to playpause\nend tell",
                            actionDescription: "Toggle playback",
                            parameters: [],
                            reliabilityScore: 0.9,
                            avgExecutionTimeMS: 300
                        )
                    ],
                    shellCommands: [
                        ShellCommandEntry(
                            name: "Open Music",
                            command: "open -a Music",
                            argsTemplate: [],
                            safetyCheck: nil,
                            commandDescription: "Launch Music"
                        )
                    ],
                    commonPatterns: [],
                    knownIssues: [],
                    timingHeuristics: .init(launchDelay: 2000, actionDelay: 500)
                )
            ]
        )

        let prompt = catalog.formattedForPrompt()

        XCTAssertTrue(prompt.contains("template: tell application \"Music\" to playpause"), "scriptTemplate must reach the prompt")
        XCTAssertTrue(prompt.contains("pattern: open -a Music"), "shell command must reach the prompt")
    }

    // MARK: - H03-F04: authorization timeout clamping

    func testAuthorizationTimeoutClampsInvalidValues() {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: "authorizationTimeoutSeconds")

        defer {
            if let original = original as? String { defaults.set(original, forKey: "authorizationTimeoutSeconds") }
            else { defaults.removeObject(forKey: "authorizationTimeoutSeconds") }
        }

        defaults.set(0, forKey: "authorizationTimeoutSeconds")
        XCTAssertEqual(AppSettings().authorizationTimeout, 15, "stored 0 must fall back to the 15s default")

        defaults.set(45, forKey: "authorizationTimeoutSeconds")
        XCTAssertEqual(AppSettings().authorizationTimeout, 30, "over-range values clamp to 30")

        defaults.set(7, forKey: "authorizationTimeoutSeconds")
        XCTAssertEqual(AppSettings().authorizationTimeout, 7)

        defaults.removeObject(forKey: "authorizationTimeoutSeconds")
        XCTAssertEqual(AppSettings().authorizationTimeout, 15)
    }

    // MARK: - H24-F07: retry attempts reporting

    func testRetryReportingAttemptsCountsSuccessfulFirstAttempt() async throws {
        let (value, attempts) = try await RetryHelper.withRetryReportingAttempts(maxAttempts: 3) { 42 }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(attempts, 1)
    }

    func testRetryReportingAttemptsCountsRetriesUntilSuccess() async throws {
        var calls = 0
        let recorded = try await RetryHelper.withRetryReportingAttempts(
            maxAttempts: 3,
            retryableCheck: { _ in true }
        ) {
            calls += 1
            if calls < 3 { throw LLMGeneratorError.apiError("500 boom") }
            return "done"
        }
        XCTAssertEqual(recorded.value, "done")
        XCTAssertEqual(recorded.attempts, 3)
    }

    func testRetryReportingAttemptsRecordsFailingAttemptBeforeThrow() async {
        var lastRecorded = 0
        do {
            _ = try await RetryHelper.withRetryReportingAttempts(
                maxAttempts: 3,
                recordAttempt: { lastRecorded = $0 }
            ) { throw LLMGeneratorError.apiError("fatal") }
            XCTFail("Expected throw")
        } catch {
            XCTAssertEqual(lastRecorded, 1, "non-retryable failure on attempt 1 must report attempt 1")
        }
    }

    // MARK: - H10-F04: Recent fetch does not silently drop past a cap

    @MainActor
    func testFetchEnabledCommandsReturnsAllWithoutFetchLimit() throws {
        let schema = Schema([Command.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)

        for index in 0..<60 {
            context.insert(Command(name: String(format: "cmd%03d", index), triggerPhrases: ["p\(index)"]))
        }
        try context.save()

        let fetched = LocalCommandExecutor.fetchEnabledCommands(in: context)
        XCTAssertEqual(fetched.count, 60, "no silent cap: all enabled commands must be fetched")
    }
}