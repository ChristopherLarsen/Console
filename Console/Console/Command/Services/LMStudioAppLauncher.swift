import AppKit

/// Launches the LM Studio desktop app from Console.
nonisolated enum LMStudioAppLauncher {
    /// Bundle identifiers used by LM Studio releases.
    private static let bundleIdentifiers = ["ai.elementlabs.lmstudio"]

    /// Launches LM Studio without activating it.
    /// Returns false when the app is not installed or fails to open.
    @MainActor
    static func launchInBackground() async -> Bool {
        guard let appURL = bundleIdentifiers.lazy.compactMap({
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }).first else {
            return false
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            return true
        } catch {
            return false
        }
    }
}
