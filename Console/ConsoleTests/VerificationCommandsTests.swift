import XCTest
import SwiftData
@testable import Console

final class VerificationCommandsTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VerificationCommandsTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        super.tearDown()
    }

    private func makeLog(result: CommandLogResult = .success) -> CommandExecutionLog {
        CommandExecutionLog(
            id: UUID(),
            commandType: .user,
            timestamp: Date(),
            triggerWord: "console",
            rawTranscript: "open test app",
            strippedTranscript: "open test app",
            matchedCommand: "Open Test App",
            matchConfidence: 0.9,
            executionResult: result,
            executionDuration: 0.5,
            errorMessage: nil
        )
    }

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

    // MARK: - H24-F03: retention covers non command-log files

    func testExtractDateParsesGenerationFailureFilenames() {
        let service = LogCleanupService.shared
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        let failureURL = tempDirectory.appendingPathComponent("generation-failure-2026-09-01-120000.md")
        let parsed = service.extractDate(from: failureURL, formatter: formatter)
        XCTAssertNotNil(parsed, "generation-failure files must yield a retention date")
        let components = Calendar.current.dateComponents([.year, .month, .day], from: parsed!)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 9)
        XCTAssertEqual(components.day, 1)

        let commandLogURL = tempDirectory.appendingPathComponent("command-log-2026-08-30.md")
        let commandLogDate = service.extractDate(from: commandLogURL, formatter: formatter)
        XCTAssertNotNil(commandLogDate)

        let undatedURL = tempDirectory.appendingPathComponent("no-date-here.md")
        XCTAssertNil(service.extractDate(from: undatedURL, formatter: formatter))
    }

    // MARK: - H24-F04/F05: write buffer integrity

    private func makeFileManager() -> CommandLogFileManager {
        CommandLogFileManager(logsDirectory: tempDirectory)
    }

    func testFlushKeepsBufferWhenWriteSkippedForSizeCap() throws {
        let fileManager = makeFileManager()
        let todayURL = fileManager.todayLogPath()

        // Fill today's log to the size cap.
        try Data(repeating: UInt8(ascii: "x"), count: 10 * 1024 * 1024).write(to: todayURL)

        fileManager.saveLog(makeLog())
        fileManager.flushBuffer()

        // Cap blocks the write; the batch must be retained, not dropped.
        let contentAfterCap = try String(contentsOf: todayURL, encoding: .utf8)
        XCTAssertFalse(contentAfterCap.contains("Open Test App"), "cap-skip must not append to the capped file")

        // Retained entries surface once the cap no longer blocks.
        try FileManager.default.removeItem(at: todayURL)
        fileManager.flushBuffer()
        let contentAfterRetry = try String(contentsOf: fileManager.todayLogPath(), encoding: .utf8)
        XCTAssertTrue(contentAfterRetry.contains("Open Test App"), "buffered entries must survive a skipped flush")
    }

    func testDeleteAllLogsClearsPendingBuffer() throws {
        let fileManager = makeFileManager()

        fileManager.saveLog(makeLog())
        fileManager.flushBuffer()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileManager.todayLogPath().path))

        // Buffered entry that was never flushed must not resurrect the file.
        fileManager.saveLog(makeLog(result: .failed))
        fileManager.deleteAllLogs()
        fileManager.flushBuffer()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileManager.todayLogPath().path),
                       "deleteAllLogs must also drop buffered entries")
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

    // MARK: - H24-F02/F06: cancelled and denied runs log distinctly

    @MainActor
    func testRecordVoiceExecutionLogMarksCancelledRuns() {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: "enableCommandLogging")
        defaults.set(true, forKey: "enableCommandLogging")
        defer {
            if let original = original as? Bool { defaults.set(original, forKey: "enableCommandLogging") }
            else { defaults.removeObject(forKey: "enableCommandLogging") }
        }

        let viewModel = MenuBarViewModel()
        let command = Command(name: "Long Task", triggerPhrases: ["long"])
        let result = ExecutionResult(
            command: command,
            logs: [],
            overallSuccess: false,
            totalDurationMs: 10,
            wasCancelled: true
        )
        viewModel.recordVoiceExecutionLog(
            run: CommandRun(id: UUID(), result: result),
            triggerWord: "console",
            rawTranscript: "long task",
            strippedTranscript: "long task",
            matchedCommand: "Long Task",
            confidence: 1.0,
            duration: 1.0
        )

        XCTAssertEqual(viewModel.recentLogs.first?.executionResult, .cancelled)
    }

    @MainActor
    func testRecordVoiceExecutionLogRecordsDeniedAuthorizationMessage() {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: "enableCommandLogging")
        defaults.set(true, forKey: "enableCommandLogging")
        defer {
            if let original = original as? Bool { defaults.set(original, forKey: "enableCommandLogging") }
            else { defaults.removeObject(forKey: "enableCommandLogging") }
        }

        let viewModel = MenuBarViewModel()
        let command = Command(name: "Sensitive", triggerPhrases: ["sensitive"])
        let result = ExecutionResult(
            command: command,
            logs: [],
            overallSuccess: false,
            totalDurationMs: 0,
            authorizationDenied: true
        )
        viewModel.recordVoiceExecutionLog(
            run: CommandRun(id: UUID(), result: result),
            triggerWord: "console",
            rawTranscript: "sensitive",
            strippedTranscript: "sensitive",
            matchedCommand: "Sensitive",
            confidence: 1.0,
            duration: 0.0
        )

        XCTAssertEqual(viewModel.recentLogs.first?.executionResult, .failed)
        XCTAssertEqual(viewModel.recentLogs.first?.errorMessage, "Authorization denied")
    }
}