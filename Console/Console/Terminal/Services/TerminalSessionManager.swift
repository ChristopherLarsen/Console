import SwiftUI
import SwiftTerm

/// Manages the persistent terminal session.
/// Owns the LocalProcessTerminalView so the shell survives panel hide/show.
@Observable
final class TerminalSessionManager {

    /// The shared terminal view instance.
    private(set) var terminalView: LocalProcessTerminalView?

    /// Whether the shell process is currently running.
    var isRunning: Bool {
        terminalView != nil
    }

    /// Coordinator for terminal delegate callbacks.
    private var coordinator: TerminalCoordinator?

    init() {}

    /// Gets or creates the terminal view.
    func getOrCreateTerminalView() -> LocalProcessTerminalView {
        if let existing = terminalView {
            return existing
        }

        let newTerminal = LocalProcessTerminalView(frame: .zero)
        configureAppearance(newTerminal)

        let newCoordinator = TerminalCoordinator()
        self.coordinator = newCoordinator
        newTerminal.processDelegate = newCoordinator

        newTerminal.startProcess(
            executable: "/bin/zsh",
            args: ["--login"],
            environment: nil,
            execName: "zsh"
        )

        self.terminalView = newTerminal
        return newTerminal
    }

    /// Request keyboard focus for the terminal.
    func focusTerminal() {
        guard let terminal = terminalView else { return }
        DispatchQueue.main.async {
            terminal.window?.makeFirstResponder(terminal)
        }
    }

    /// Warms the terminal view's layout, font metrics, and draw machinery
    /// while the drawer is closed so the first expansion is instant. The view
    /// is created with a zero frame and never laid out until mounted, which
    /// is where the first-open lag comes from. Safe to call repeatedly: it
    /// only runs while the view exists and is not yet in a view hierarchy.
    func preheatTerminalView() {
        let terminal = getOrCreateTerminalView()
        guard terminal.superview == nil, terminal.frame.size == .zero else { return }

        // A realistic drawer-sized frame forces font measurement, cell-grid
        // sizing, TextKit setup, and one draw pass now instead of on mount.
        // The shell also receives an early pty resize for a sane grid.
        terminal.setFrameSize(NSSize(width: 800, height: 500))
        terminal.layoutSubtreeIfNeeded()
        terminal.needsDisplay = true
        terminal.displayIfNeeded()
    }

    // MARK: - Configuration

    private func configureAppearance(_ terminalView: LocalProcessTerminalView) {
        terminalView.nativeBackgroundColor = .black
        terminalView.nativeForegroundColor = NSColor(calibratedRed: 0.9, green: 0.9, blue: 0.9, alpha: 1.0)
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    }
}

// MARK: - Terminal Coordinator

/// Handles delegate callbacks from the terminal view.
private final class TerminalCoordinator: NSObject, LocalProcessTerminalViewDelegate {

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // SwiftTerm handles SIGWINCH internally via pty ioctl
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        // Could update window title if needed
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // Could track shell's current directory
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        if let code = exitCode {
            print("[Terminal] Process exited with code: \(code)")
        } else {
            print("[Terminal] Process exited")
        }
    }
}
