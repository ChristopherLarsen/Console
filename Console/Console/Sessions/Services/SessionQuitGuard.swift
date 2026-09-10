import AppKit

/// Confirmation gate between the user and app termination while live Claude
/// sessions would be killed with the app. Installed through
/// `NSApplicationDelegateAdaptor`, so every quit path (⌘Q, File → Quit, Dock,
/// menu bar item) flows through `applicationShouldTerminate`. The actual
/// process teardown stays in ConsoleApp's `willTerminate` observer, which only
/// runs after this guard allows termination.
@MainActor
final class SessionQuitGuard: NSObject, NSApplicationDelegate {

    /// Supplies the sessions to evaluate. Assigned by ConsoleApp after its
    /// stores exist; nil behaves as "no sessions".
    var sessionsProvider: (@MainActor () -> [ConsoleSession])?

    /// True when the dialog must never appear (test hosts). UI tests inject
    /// fake live sessions and terminate the app at teardown; a modal there
    /// would hang the runner.
    var isSuppressed = false

    /// Injectable so tests can exercise the decision without a modal AppKit
    /// alert. Returns true when quitting is confirmed.
    var presentConfirmation: (@MainActor (_ liveCount: Int) -> Bool)?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isSuppressed else { return .terminateNow }

        let liveSessions = Self.liveSessions(from: sessionsProvider?() ?? [])
        guard !liveSessions.isEmpty else { return .terminateNow }

        let confirmed = presentConfirmation?(liveSessions.count)
            ?? Self.runModalConfirmation(liveCount: liveSessions.count)
        return confirmed ? .terminateNow : .terminateCancel
    }

    /// Sessions whose Claude process is still live. Exited rows (dead
    /// processes retained for scrollback) never block a quit.
    static func liveSessions(from sessions: [ConsoleSession]) -> [ConsoleSession] {
        sessions.filter { $0.activity != .exited }
    }

    private static func runModalConfirmation(liveCount: Int) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = liveCount == 1
            ? "Quit Console and stop 1 active session?"
            : "Quit Console and stop \(liveCount) active sessions?"
        alert.informativeText = "Active sessions will be terminated and their conversations lost. "
            + "Stop each session first if you want to keep its Claude conversation."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
