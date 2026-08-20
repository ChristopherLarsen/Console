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
