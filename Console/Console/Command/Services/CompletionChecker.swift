import Foundation
import AppKit

final class CompletionChecker {
    private let fileManager = FileManager.default

    func waitForCompletion(
        _ check: CompletionCheck,
        timeout: TimeInterval
    ) async -> Bool {
        await evaluate(check, timeout: timeout).outcome == .passed
    }

    func evaluate(
        _ check: CompletionCheck,
        timeout: TimeInterval
    ) async -> CompletionCheckRun {
        let start = Date()
        func finish(_ outcome: CompletionCheckOutcome) -> CompletionCheckRun {
            CompletionCheckRun(
                type: check.type,
                value: check.value,
                elapsedMs: max(0, Int(Date().timeIntervalSince(start) * 1000)),
                outcome: outcome
            )
        }

        if Task.isCancelled { return finish(.cancelled) }
        let deadline = Date().addingTimeInterval(timeout)
        let pollInterval: UInt64 = 100_000_000

        switch check.type {
        case .delay:
            guard let ms = Int(check.value), ms >= 0 else { return finish(.failed) }
            if Double(ms) / 1000.0 > timeout { return finish(.timedOut) }
            do {
                try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                return finish(Task.isCancelled ? .cancelled : .passed)
            } catch {
                return finish(.cancelled)
            }

        case .appRunning:
            while true {
                if Task.isCancelled { return finish(.cancelled) }
                if isAppRunning(check.value) { return finish(.passed) }
                guard Date() < deadline else { break }
                if await sleepOrCancel(nanoseconds: pollInterval) { return finish(.cancelled) }
            }

        case .fileExists:
            while true {
                if Task.isCancelled { return finish(.cancelled) }
                if doesFileExist(check.value) { return finish(.passed) }
                guard Date() < deadline else { break }
                if await sleepOrCancel(nanoseconds: pollInterval) { return finish(.cancelled) }
            }

        case .windowTitle:
            while true {
                if Task.isCancelled { return finish(.cancelled) }
                if doesWindowExist(withTitle: check.value) { return finish(.passed) }
                guard Date() < deadline else { break }
                if await sleepOrCancel(nanoseconds: pollInterval) { return finish(.cancelled) }
            }
        }

        return finish(.timedOut)
    }

    /// Returns `true` when the wait ended because the task was cancelled.
    private func sleepOrCancel(nanoseconds: UInt64) async -> Bool {
        if Task.isCancelled { return true }
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
        } catch {
            return true
        }
        return Task.isCancelled
    }

    // MARK: - Check Implementations

    func isAppRunning(_ identifier: String) -> Bool {
        let apps = NSWorkspace.shared.runningApplications

        if apps.contains(where: { $0.localizedName == identifier }) {
            return true
        }
        if apps.contains(where: { $0.bundleIdentifier == identifier }) {
            return true
        }
        if apps.contains(where: {
            $0.executableURL?.lastPathComponent.lowercased() == identifier.lowercased()
        }) {
            return true
        }

        return false
    }

    func doesFileExist(_ path: String) -> Bool {
        let expanded = NSString(string: path).expandingTildeInPath
        return fileManager.fileExists(atPath: expanded)
    }

    func doesWindowExist(withTitle title: String) -> Bool {
        findWindow(withTitle: title) != nil
    }

    // MARK: - Window Helpers

    func findWindow(withTitle title: String) -> [String: Any]? {
        // An empty title must not substring-match every named window.
        guard !title.isEmpty else { return nil }
        guard let windows = CGWindowListCopyWindowInfo(
            .optionOnScreenOnly, kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        for window in windows {
            guard let windowTitle = window[kCGWindowName as String] as? String else {
                continue
            }
            if windowTitle == title || windowTitle.contains(title) {
                return window
            }
        }

        return nil
    }

    // MARK: - Debugging Helpers

    func getAllWindows() -> [[String: Any]] {
        guard let windows = CGWindowListCopyWindowInfo(
            .optionOnScreenOnly, kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        return windows
    }

    func getAllRunningApps() -> [RunningAppInfo] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = app.bundleIdentifier else { return nil }
            return RunningAppInfo(
                name: app.localizedName ?? "Unknown",
                bundleID: bundleID,
                executableName: app.executableURL?.lastPathComponent ?? "Unknown",
                isActive: app.isActive
            )
        }
    }
}

// MARK: - Supporting Types

struct RunningAppInfo {
    let name: String
    let bundleID: String
    let executableName: String
    let isActive: Bool
}
