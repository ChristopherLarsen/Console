import Foundation

final class LogCleanupService {
    static let shared = LogCleanupService()

    private let logManager = CommandLogFileManager.shared
    private let maxDirectoryBytes: Int64 = 50 * 1024 * 1024
    private let minimumRetainedDays = 1
    private let cleanupQueue = DispatchQueue(label: "com.console.logcleanup", qos: .background)

    private init() {}

    // Runs cleanup once at launch, then schedules a daily repeat
    func startBackgroundCleanup() {
        cleanupQueue.async { self.performCleanup() }
        scheduleDailyCleanup()
    }

    func performCleanup() {
        deleteExpiredLogs(olderThan: minimumRetainedDays)
        enforceDirectorySizeLimit()
    }

    // MARK: - Retention

    private func deleteExpiredLogs(olderThan days: Int) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        for file in logManager.getAllLogFiles() {
            guard let fileDate = extractDate(from: file, formatter: formatter) else { continue }
            if fileDate < cutoff {
                logManager.deleteLog(at: file)
                printDebug("[LogCleanupService] Deleted expired log: \(file.lastPathComponent)")
            }
        }
    }

    // MARK: - Size Limit

    // Deletes oldest files until under the size cap, always keeping the last 3 days
    private func enforceDirectorySizeLimit() {
        var totalSize = logManager.totalLogsSize()
        guard totalSize > maxDirectoryBytes else { return }

        let cutoff = Calendar.current.date(byAdding: .day, value: -minimumRetainedDays, to: Date()) ?? Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        // Iterate oldest-first (getAllLogFiles returns newest-first)
        let files = logManager.getAllLogFiles().reversed()
        for file in files {
            guard totalSize > maxDirectoryBytes else { break }
            guard let fileDate = extractDate(from: file, formatter: formatter), fileDate < cutoff else { continue }

            let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
            let fileSize = (attrs?[.size] as? Int64) ?? 0
            logManager.deleteLog(at: file)
            totalSize -= fileSize
            printDebug("[LogCleanupService] Deleted log for size limit: \(file.lastPathComponent)")
        }
    }

    // MARK: - Daily Timer

    private func scheduleDailyCleanup() {
        DispatchQueue.main.async {
            Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
                self?.cleanupQueue.async { self?.performCleanup() }
            }
        }
    }

    // MARK: - Helpers

    private func extractDate(from url: URL, formatter: DateFormatter) -> Date? {
        let name = url.deletingPathExtension().lastPathComponent
        let dateString = name.replacingOccurrences(of: "command-log-", with: "")
        return formatter.date(from: dateString)
    }
}
