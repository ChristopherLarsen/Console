import Foundation
import AppKit

final class CompletionChecker {
    private let fileManager = FileManager.default

    func waitForCompletion(
        _ check: CompletionCheck,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let pollInterval: UInt64 = 100_000_000

        switch check.type {
        case .delay:
            if let ms = Int(check.value) {
                try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                return true
            }
            return false

        case .appRunning:
            while Date() < deadline {
                if isAppRunning(check.value) { return true }
                try? await Task.sleep(nanoseconds: pollInterval)
            }

        case .fileExists:
            while Date() < deadline {
                if doesFileExist(check.value) { return true }
                try? await Task.sleep(nanoseconds: pollInterval)
            }

        case .windowTitle:
            while Date() < deadline {
                if doesWindowExist(withTitle: check.value) { return true }
                try? await Task.sleep(nanoseconds: pollInterval)
            }
        }

        return false
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
