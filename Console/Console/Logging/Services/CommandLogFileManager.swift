import AppKit
import Foundation

final class CommandLogFileManager: @unchecked Sendable {
    static let shared = CommandLogFileManager()

    private let queue = DispatchQueue(label: "com.console.commandlogging")
    private let maxFileBytes: Int64 = 10 * 1024 * 1024
    private let bufferFlushCount = 5
    private let bufferFlushInterval: TimeInterval = 30

    // ~/Library/Application Support/Console/logs/
    static let defaultLogsDirectory: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("Console", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
    }()

    let logsDirectory: URL

    // Write buffer — accessed only on `queue`
    private var pendingEntries: [CommandExecutionLog] = []
    private var flushTimer: DispatchSourceTimer?
    private var terminationObserver: NSObjectProtocol?

    /// `logsDirectory` is injectable so retention/buffer behavior can be tested
    /// against a scratch directory instead of the user's real logs.
    init(logsDirectory: URL? = nil) {
        self.logsDirectory = logsDirectory ?? Self.defaultLogsDirectory
        #if DEBUG
        ensureDirectoryExists()
        startFlushTimer()
        registerTerminationFlush()
        #endif
    }

    // MARK: - Save

    func saveLog(_ log: CommandExecutionLog) {
        #if DEBUG
        queue.async { [self] in
            pendingEntries.append(log)
            if pendingEntries.count >= bufferFlushCount {
                writePendingEntries()
            }
        }
        #endif
    }

    // Force-flush the buffer to disk (called on termination and externally)
    func flushBuffer() {
        #if DEBUG
        queue.sync { [self] in
            writePendingEntries()
        }
        #endif
    }

    // MARK: - Format

    func formatLogAsMarkdown(_ log: CommandExecutionLog, entryIndex: Int = 0) -> String {
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"
        let time = timeFormatter.string(from: log.timestamp)

        let title = log.matchedCommand ?? log.strippedTranscript
        let indexLabel = entryIndex > 0 ? "#\(entryIndex) " : ""
        var md = "\n## \(indexLabel)[\(time)] \(log.statusEmoji) \(title)\n\n"
        md += "| Field | Value |\n"
        md += "|-------|-------|\n"
        md += "| **Trigger Word** | \(log.triggerWord) |\n"
        md += "| **Raw Speech** | \"\(log.rawTranscript)\" |\n"
        md += "| **Cleaned Command** | \"\(log.strippedTranscript)\" |\n"
        md += "| **Matched Command** | \(log.matchedCommand ?? "—") |\n"
        md += "| **Confidence** | \(log.confidencePercentage) |\n"
        md += "| **Execution Time** | \(log.formattedDuration) |\n"
        md += "| **Result** | \(log.statusEmoji) \(log.statusLabel) |\n"

        if let error = log.errorMessage {
            md += "| **Error** | \(error) |\n"
        }

        md += "\n---\n"
        return md
    }

    // MARK: - Query

    func todayLogPath() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let filename = "command-log-\(formatter.string(from: Date())).md"
        return logsDirectory.appendingPathComponent(filename)
    }

    func getAllLogFiles() -> [URL] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: logsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return contents
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func getLogContent(for date: Date) -> String? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let filename = "command-log-\(formatter.string(from: date)).md"
        let fileURL = logsDirectory.appendingPathComponent(filename)
        return try? String(contentsOf: fileURL, encoding: .utf8)
    }

    // MARK: - Deletion

    // Overwrites file content with zeros before deletion
    func deleteLog(at url: URL) {
        if let handle = try? FileHandle(forWritingTo: url) {
            let size = handle.seekToEndOfFile()
            handle.seek(toFileOffset: 0)
            handle.write(Data(repeating: 0, count: Int(size)))
            handle.closeFile()
        }
        try? FileManager.default.removeItem(at: url)
    }

    func deleteAllLogs() {
        // Drop buffered-but-unwritten entries too, or the next flush would
        // resurrect the deleted log file.
        queue.sync { [self] in
            pendingEntries.removeAll()
        }
        for file in getAllLogFiles() {
            deleteLog(at: file)
        }
    }

    func deleteOldLogs(olderThan days: Int) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        for file in getAllLogFiles() {
            let name = file.deletingPathExtension().lastPathComponent
            let dateString = name.replacingOccurrences(of: "command-log-", with: "")
            if let fileDate = formatter.date(from: dateString), fileDate < cutoff {
                deleteLog(at: file)
            }
        }
    }

    // MARK: - Stats

    func totalLogsSize() -> Int64 {
        let fm = FileManager.default
        return getAllLogFiles().reduce(into: Int64(0)) { total, url in
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            total += (attrs?[.size] as? Int64) ?? 0
        }
    }

    // MARK: - Private — Buffered Write

    // Must be called on `queue`
    private func writePendingEntries() {
        guard !pendingEntries.isEmpty else { return }
        let fileURL = todayLogPath()
        let isNewFile = !FileManager.default.fileExists(atPath: fileURL.path)

        // Enforce 10MB limit — skip writes if file already at cap. The buffer
        // is kept so the batch is not silently lost.
        if !isNewFile, fileSize(at: fileURL) >= maxFileBytes {
            printDebug("[CommandLogFileManager] File size limit reached, skipping write")
            return
        }

        let batch = pendingEntries
        do {
            if isNewFile {
                let firstLog = batch[0]
                var content = fileHeader(for: firstLog.timestamp, stats: newStats(for: firstLog.executionResult))
                content += formatLogAsMarkdown(firstLog, entryIndex: 1)

                var runningStats = newStats(for: firstLog.executionResult)
                for i in 1..<batch.count {
                    incrementStats(&runningStats, result: batch[i].executionResult)
                    content += formatLogAsMarkdown(batch[i], entryIndex: runningStats.total)
                }

                updateStatsInPlace(in: &content, stats: runningStats)
                try content.write(to: fileURL, atomically: true, encoding: .utf8)
            } else {
                var content = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
                for log in batch {
                    let stats = parseAndIncrementStats(in: &content, result: log.executionResult)
                    content += formatLogAsMarkdown(log, entryIndex: stats.total)
                }
                try content.write(to: fileURL, atomically: true, encoding: .utf8)
            }
            // Only discard the buffer after a successful write; a failure keeps
            // the entries for the next flush.
            pendingEntries.removeAll()
        } catch {
            printDebug("[CommandLogFileManager] Failed to write log batch: \(error.localizedDescription)")
        }
    }

    private func fileSize(at url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? Int64) ?? 0
    }

    // MARK: - Private — Flush Timer

    private func startFlushTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + bufferFlushInterval, repeating: bufferFlushInterval)
        timer.setEventHandler { [weak self] in
            self?.writePendingEntries()
        }
        timer.resume()
        flushTimer = timer
    }

    // Flushes buffer when the app is about to terminate
    private func registerTerminationFlush() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.flushBuffer()
        }
    }

    // MARK: - Private — Stats

    private struct LogStats {
        var total: Int
        var success: Int
        var failed: Int
        var noMatch: Int
    }

    private func newStats(for result: CommandLogResult) -> LogStats {
        var stats = LogStats(total: 1, success: 0, failed: 0, noMatch: 0)
        switch result {
        case .success: stats.success = 1
        case .failed: stats.failed = 1
        case .noMatch: stats.noMatch = 1
        case .cancelled: stats.failed = 1
        }
        return stats
    }

    private func incrementStats(_ stats: inout LogStats, result: CommandLogResult) {
        stats.total += 1
        switch result {
        case .success: stats.success += 1
        case .failed, .cancelled: stats.failed += 1
        case .noMatch: stats.noMatch += 1
        }
    }

    // Finds the statistics line, parses counts, increments, and replaces in-place
    private func parseAndIncrementStats(in content: inout String, result: CommandLogResult) -> LogStats {
        let pattern = #"\*\*Statistics\*\*: (\d+) entries? \| ✅ (\d+) success \| ❌ (\d+) failed \| ⚠️ (\d+) no match"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)) else {
            return LogStats(total: 1, success: 0, failed: 0, noMatch: 0)
        }

        func extractInt(_ i: Int) -> Int {
            guard let range = Range(match.range(at: i), in: content) else { return 0 }
            return Int(content[range]) ?? 0
        }

        var stats = LogStats(total: extractInt(1), success: extractInt(2), failed: extractInt(3), noMatch: extractInt(4))
        incrementStats(&stats, result: result)

        let replacement = statsLine(stats)
        let matchRange = Range(match.range, in: content)!
        content.replaceSubrange(matchRange, with: replacement)

        return stats
    }

    private func updateStatsInPlace(in content: inout String, stats: LogStats) {
        let pattern = #"\*\*Statistics\*\*: \d+ entries? \| ✅ \d+ success \| ❌ \d+ failed \| ⚠️ \d+ no match"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
              let matchRange = Range(match.range, in: content) else { return }
        content.replaceSubrange(matchRange, with: statsLine(stats))
    }

    private func statsLine(_ stats: LogStats) -> String {
        let entryWord = stats.total == 1 ? "entry" : "entries"
        return "**Statistics**: \(stats.total) \(entryWord) | ✅ \(stats.success) success | ❌ \(stats.failed) failed | ⚠️ \(stats.noMatch) no match"
    }

    private func ensureDirectoryExists() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: logsDirectory.path) {
            do {
                try fm.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
            } catch {
                printDebug("[CommandLogFileManager] Failed to create logs directory: \(error.localizedDescription)")
            }
        }
    }

    private func fileHeader(for date: Date, stats: LogStats) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy"
        let dateString = formatter.string(from: date)

        return "# Command Execution Log - \(dateString)\n\n> **Privacy Notice**: This file contains voice commands and execution results.\n> These logs are stored locally and are not transmitted anywhere.\n\n\(statsLine(stats))\n\n---\n"
    }
}
