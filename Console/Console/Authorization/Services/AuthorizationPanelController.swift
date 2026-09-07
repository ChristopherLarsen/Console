import AppKit
import SwiftUI

/// Manages a standalone floating NSPanel for the authorization dialog.
@MainActor
final class AuthorizationPanelController: NSObject, NSWindowDelegate {
    static let shared = AuthorizationPanelController()
    private var panel: NSPanel?
    private let voiceHandler = AuthorizationVoiceHandler()

    override init() {}

    func show(command: Command) {
        dismiss()

        let settings = AppSettings()
        let allowVoiceAuth = settings.voiceOnlyAuthorization
        let timeout = settings.authorizationTimeoutSeconds

        let dialog = AuthorizationDialog(
            command: command,
            authorizationWords: settings.authorizationWords,
            allowVoiceAuth: allowVoiceAuth,
            initialTimeout: timeout,
            onAuthorize: { [weak self] in
                self?.voiceHandler.stopListening()
                AuthorizationManager.shared.approve()
            },
            onCancel: { [weak self] in
                self?.voiceHandler.stopListening()
                AuthorizationManager.shared.deny()
            }
        )

        let hosting = NSHostingController(rootView: dialog)
        let size = hosting.sizeThatFits(in: NSSize(width: 420, height: 600))
        hosting.view.frame.size = size

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentViewController = hosting
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.center()

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()

        self.panel = panel

        if allowVoiceAuth {
            voiceHandler.startListening(authorizationWords: settings.authorizationWords)
        }
    }

    func dismiss() {
        voiceHandler.stopListening()
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - NSWindowDelegate

    /// Closing the panel chrome (traffic light / Cmd-W) is a cancellation:
    /// deny the pending request instead of leaving a hidden live prompt that
    /// voice can still approve.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else { return }
        AuthorizationManager.shared.deny()
    }
}
