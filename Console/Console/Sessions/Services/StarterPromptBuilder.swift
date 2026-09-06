import Foundation

/// Privacy gate for contextual launches. WebView-derived ticket and
/// merge-request fields are local routing and display data. They must never
/// be interpolated into a prompt, process argument, environment value, or
/// terminal-send payload for Claude.
enum StarterPromptBuilder {
    /// Shown in the intent launcher so the developer knows work context is
    /// typed into the idle session, not generated from the page.
    static let developerContextNotice =
        "Ticket and merge-request details stay in Console for naming and folder routing. Type work context into the idle session yourself."

    /// Always `nil`. Contextual launches open idle; source metadata is not
    /// turned into a starter prompt on any path.
    static func prompt(for purpose: SessionPurpose, source: SessionLaunchSource?) -> String? {
        _ = purpose
        _ = source
        return nil
    }
}

extension SessionPurpose {
    /// No purpose generates a source-derived starter prompt.
    var generatesStarterPrompt: Bool { false }
}
