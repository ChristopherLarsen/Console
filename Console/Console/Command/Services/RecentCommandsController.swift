import AppKit
import SwiftUI

@MainActor
final class RecentCommandsController {
    static let shared = RecentCommandsController()
    private var panel: NSWindow?

    private init() {}

    func show(commands: [Command], wakeWords: [String] = []) {
        dismiss()

        let triggerWord = resolveTriggerWord(from: wakeWords)

        let view = RecentCommandsView(
            commands: commands,
            triggerWord: triggerWord,
            onDismiss: { [weak self] in self?.dismiss() },
            onExecute: { [weak self] command in
                self?.dismiss()
                Task {
                    let executor = LocalCommandExecutor()
                    _ = await executor.execute(command)
                }
            }
        )

        let hosting = NSHostingController(rootView: view)
        let size = NSSize(width: 320, height: 400)
        hosting.view.frame.size = size
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor

        let panel = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "CommandsPanel"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.identifier = NSUserInterfaceItemIdentifier("CommandsPanel")
        panel.setAccessibilityIdentifier("CommandsPanel")
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.isMovableByWindowBackground = true
        panel.contentViewController = hosting

        positionPanel(panel)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func resolveTriggerWord(from wakeWords: [String]) -> String {
        if let last = UserDefaults.standard.string(forKey: "lastUsedTriggerWord"),
           !last.isEmpty {
            return last.capitalized
        }
        if let first = wakeWords.first, !first.isEmpty {
            return first.capitalized
        }
        return "Console"
    }

    private func positionPanel(_ panel: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        let panelSize = panel.frame.size
        let topInset: CGFloat = 40

        // Center horizontally under the menu bar status item
        var centerX = screenFrame.midX
        if let button = MenuBarManager.shared.statusItem?.button,
           let buttonWindow = button.window {
            let buttonRect = button.convert(button.bounds, to: nil)
            let screenRect = buttonWindow.convertToScreen(buttonRect)
            centerX = screenRect.midX
        }

        let x = centerX - panelSize.width / 2
        let y = screenFrame.maxY - panelSize.height - topInset
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
