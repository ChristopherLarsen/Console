import XCTest
@testable import Console

@MainActor
final class CommandLoggingTests: XCTestCase {

    // MARK: - Helper

    private func makeLog(
        result: CommandLogResult = .success,
        matchedCommand: String? = "Open Terminal",
        confidence: Double? = 0.95,
        duration: TimeInterval? = 1.2,
        error: String? = nil,
        rawTranscript: String = "console open terminal",
        strippedTranscript: String = "open terminal",
        commandType: CommandType = .user
    ) -> CommandExecutionLog {
        CommandExecutionLog(
            id: UUID(),
            commandType: commandType,
            timestamp: Date(),
            triggerWord: "console",
            rawTranscript: rawTranscript,
            strippedTranscript: strippedTranscript,
            matchedCommand: matchedCommand,
            matchConfidence: confidence,
            executionResult: result,
            executionDuration: duration,
            errorMessage: error
        )
    }

    // MARK: - Log Model

    func testFormattedTimestamp() {
        let log = makeLog()
        let ts = log.formattedTimestamp
        XCTAssertFalse(ts.isEmpty)
        XCTAssertTrue(ts.contains("-"), "Timestamp should contain date separators")
    }

    func testConfidencePercentage() {
        XCTAssertEqual(makeLog(confidence: 0.95).confidencePercentage, "95%")
        XCTAssertEqual(makeLog(confidence: 1.0).confidencePercentage, "100%")
        XCTAssertEqual(makeLog(confidence: nil).confidencePercentage, "N/A")
    }

    func testStatusEmoji() {
        XCTAssertEqual(makeLog(result: .success).statusEmoji, "✅")
        XCTAssertEqual(makeLog(result: .failed).statusEmoji, "❌")
        XCTAssertEqual(makeLog(result: .noMatch).statusEmoji, "⚠️")
        XCTAssertEqual(makeLog(result: .cancelled).statusEmoji, "🚫")
    }

    func testStatusLabel() {
        XCTAssertEqual(makeLog(result: .success).statusLabel, "Success")
        XCTAssertEqual(makeLog(result: .failed).statusLabel, "Failed")
        XCTAssertEqual(makeLog(result: .noMatch).statusLabel, "No Match")
        XCTAssertEqual(makeLog(result: .cancelled).statusLabel, "Cancelled")
    }

    func testFormattedDuration() {
        XCTAssertEqual(makeLog(duration: 1.2).formattedDuration, "1.2s")
        XCTAssertEqual(makeLog(duration: nil).formattedDuration, "N/A")
        XCTAssertEqual(makeLog(duration: 0.0).formattedDuration, "0.0s")
    }

    @MainActor
    func testCodable() async throws {
        let log = makeLog()
        let data = try JSONEncoder().encode(log)
        let decoded = try JSONDecoder().decode(CommandExecutionLog.self, from: data)
        XCTAssertEqual(decoded.id, log.id)
        XCTAssertEqual(decoded.triggerWord, log.triggerWord)
        XCTAssertEqual(decoded.executionResult, log.executionResult)
    }

    // MARK: - Markdown Formatting

    func testMarkdownContainsAllFields() {
        let log = makeLog()
        let md = CommandLogFileManager.shared.formatLogAsMarkdown(log, entryIndex: 1)

        XCTAssertTrue(md.contains("console"), "Should contain trigger word")
        XCTAssertTrue(md.contains("console open terminal"), "Should contain raw transcript")
        XCTAssertTrue(md.contains("open terminal"), "Should contain stripped transcript")
        XCTAssertTrue(md.contains("Open Terminal"), "Should contain matched command")
        XCTAssertTrue(md.contains("95%"), "Should contain confidence")
        XCTAssertTrue(md.contains("1.2s"), "Should contain duration")
        XCTAssertTrue(md.contains("✅"), "Should contain success emoji")
        XCTAssertTrue(md.contains("#1"), "Should contain entry index")
    }

    func testMarkdownForAllResultTypes() {
        let results: [CommandLogResult] = [.success, .failed, .noMatch, .cancelled]
        for result in results {
            let log = makeLog(result: result)
            let md = CommandLogFileManager.shared.formatLogAsMarkdown(log)
            XCTAssertTrue(md.contains(log.statusEmoji), "Markdown should contain emoji for \(result)")
            XCTAssertTrue(md.contains(log.statusLabel), "Markdown should contain label for \(result)")
        }
    }

    func testMarkdownWithError() {
        let log = makeLog(result: .failed, error: "Script timed out")
        let md = CommandLogFileManager.shared.formatLogAsMarkdown(log)
        XCTAssertTrue(md.contains("Script timed out"))
    }

    func testMarkdownWithNoMatch() {
        let log = makeLog(result: .noMatch, matchedCommand: nil, confidence: nil)
        let md = CommandLogFileManager.shared.formatLogAsMarkdown(log)
        XCTAssertTrue(md.contains("—"), "No match should show em-dash for matched command")
        XCTAssertTrue(md.contains("N/A"), "No match should show N/A for confidence")
    }

    func testMarkdownEntryIndex() {
        let log = makeLog()
        let md = CommandLogFileManager.shared.formatLogAsMarkdown(log, entryIndex: 42)
        XCTAssertTrue(md.contains("#42"))
    }

    func testMarkdownSeparator() {
        let log = makeLog()
        let md = CommandLogFileManager.shared.formatLogAsMarkdown(log)
        XCTAssertTrue(md.contains("---"), "Entry should end with horizontal rule")
    }

    // MARK: - Log File Manager Directory

    func testLogsDirectoryExists() {
        let dir = CommandLogFileManager.shared.logsDirectory
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir)
        XCTAssertTrue(exists, "Logs directory should exist")
        XCTAssertTrue(isDir.boolValue, "Logs directory should be a directory")
    }

    func testTodayLogPathFormat() {
        let path = CommandLogFileManager.shared.todayLogPath()
        let filename = path.lastPathComponent
        XCTAssertTrue(filename.hasPrefix("command-log-"), "Filename should start with command-log-")
        XCTAssertTrue(filename.hasSuffix(".md"), "Filename should end with .md")
    }

    // MARK: - Statistics Line Parsing

    func testStatisticsLineFormat() {
        let log = makeLog(result: .success)
        let md = CommandLogFileManager.shared.formatLogAsMarkdown(log, entryIndex: 1)
        XCTAssertTrue(md.contains("✅"), "Success entries should contain checkmark")
    }

    // MARK: - Concurrent Writes

    func testConcurrentSaveDoesNotCrash() {
        let logs = (0..<10).map { i in
            makeLog(strippedTranscript: "concurrent command \(i)")
        }
        let expectation = XCTestExpectation(description: "Concurrent writes complete")
        expectation.expectedFulfillmentCount = 10

        for log in logs {
            DispatchQueue.global().async {
                CommandLogFileManager.shared.saveLog(log)
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 10.0)
    }

    // MARK: - Log Cleanup

    func testDeleteOldLogsDoesNotCrash() {
        CommandLogFileManager.shared.deleteOldLogs(olderThan: 365)
    }

    func testTotalLogsSizeReturnsNonNegative() {
        let size = CommandLogFileManager.shared.totalLogsSize()
        XCTAssertGreaterThanOrEqual(size, 0)
    }

    func testGetAllLogFilesReturnsArray() {
        let files = CommandLogFileManager.shared.getAllLogFiles()
        XCTAssertNotNil(files)
        for file in files {
            XCTAssertEqual(file.pathExtension, "md")
        }
    }

    // MARK: - Performance

    func testSaveLogPerformance() {
        // Measures overhead of queuing a log entry (should not block caller)
        measure {
            let log = makeLog(strippedTranscript: "perf test command")
            CommandLogFileManager.shared.saveLog(log)
        }
    }

    func testMarkdownFormattingPerformance() {
        let log = makeLog()
        measure {
            for _ in 0..<100 {
                _ = CommandLogFileManager.shared.formatLogAsMarkdown(log, entryIndex: 1)
            }
        }
    }

    func testBufferFlushPerformance() {
        // Queues multiple entries then forces a synchronous flush
        measure {
            for i in 0..<5 {
                let log = makeLog(strippedTranscript: "flush perf \(i)")
                CommandLogFileManager.shared.saveLog(log)
            }
            CommandLogFileManager.shared.flushBuffer()
        }
    }
}
