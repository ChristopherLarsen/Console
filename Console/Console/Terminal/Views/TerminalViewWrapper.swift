import SwiftUI
import SwiftTerm

/// SwiftUI wrapper for SwiftTerm's LocalProcessTerminalView.
/// Uses TerminalSessionManager to persist the shell session.
struct TerminalViewWrapper: NSViewRepresentable {

    /// Session manager that owns the persistent terminal instance.
    let sessionManager: TerminalSessionManager

    // MARK: - NSViewRepresentable

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        // Only a freshly created shell should claim keyboard focus. When the
        // drawer is expanded, this view remounts and the Claude PTY (or the
        // chevron button the user just clicked) must keep focus.
        let isNewTerminal = sessionManager.terminalView == nil
        let terminalView = sessionManager.getOrCreateTerminalView()
        if isNewTerminal {
            sessionManager.focusTerminal()
        }
        return terminalView
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // Do not steal first responder on SwiftUI refreshes. The Sessions
        // terminal must keep keyboard focus across layout changes.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Coordinator

    /// Minimal coordinator for NSViewRepresentable conformance.
    /// Actual delegate handling is in TerminalSessionManager.
    final class Coordinator: NSObject {
    }
}

#Preview {
    TerminalViewWrapper(sessionManager: TerminalSessionManager())
        .frame(width: 600, height: 400)
}
