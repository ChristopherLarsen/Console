import AppKit
import Foundation
import SwiftTerm

/// Launches the Claude PTY child for a session. Abstracted so unit tests can
/// create sessions without spawning real processes.
@MainActor
protocol SessionProcessLaunching: AnyObject {
    func makeTerminalView() -> LocalProcessTerminalView
    func launch(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String,
        terminalView: LocalProcessTerminalView
    ) throws
}

/// Production launcher: starts the resolved `claude` executable directly as the
/// PTY child. A shell is never started and `claude` is never typed into one.
final class ClaudeSessionLauncher: SessionProcessLaunching {
    func makeTerminalView() -> LocalProcessTerminalView {
        let view = ConsoleTerminalView()
        view.configureAppearance()
        return view
    }

    func launch(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String,
        terminalView: LocalProcessTerminalView
    ) throws {
        var fullEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            fullEnvironment[key] = value
        }
        let environmentEntries = fullEnvironment.map { "\($0.key)=\($0.value)" }.sorted()
        terminalView.startProcess(
            executable: executable,
            args: arguments,
            environment: environmentEntries,
            execName: "claude",
            currentDirectory: workingDirectory
        )
    }
}

/// SwiftTerm terminal configured for Console sessions. All sends go through
/// SwiftTerm's main-thread input API.
final class ConsoleTerminalView: LocalProcessTerminalView {
    init() {
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ConsoleTerminalView does not support nib initialization")
    }

    func configureAppearance() {
        nativeBackgroundColor = .black
        nativeForegroundColor = NSColor(calibratedRed: 0.9, green: 0.9, blue: 0.9, alpha: 1.0)
        font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    }
}

/// Per-session delegate bridging SwiftTerm process termination into the store.
@MainActor
final class SessionTerminalCoordinator: NSObject, LocalProcessTerminalViewDelegate {
    weak var store: SessionStore?
    let sessionID: UUID

    init(sessionID: UUID, store: SessionStore?) {
        self.sessionID = sessionID
        self.store = store
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        store?.handleProcessTerminated(sessionID: sessionID)
    }
}
