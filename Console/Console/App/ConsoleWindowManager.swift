import SwiftUI

@MainActor
final class ConsoleWindowManager {
    static var openWindow: OpenWindowAction?

    /// Registered by MainWindowConfigurator — avoids fragile identifier matching.
    static weak var mainWindow: NSWindow?

    static func bringToFront(_ id: String, openWindow: OpenWindowAction) {
        NSApp.activate(ignoringOtherApps: true)

        if id == "main", let window = mainWindow {
            window.orderFrontRegardless()
            window.makeKey()
        } else if let existing = NSApp.windows.first(where: {
            $0.identifier?.rawValue.contains(id) == true
        }) {
            existing.orderFrontRegardless()
            existing.makeKey()
        } else {
            openWindow(id: id)
            // One hop so SwiftUI has created the window before we raise it
            DispatchQueue.main.async {
                NSApp.windows.last?.orderFrontRegardless()
                NSApp.windows.last?.makeKey()
            }
        }
    }

    static func bringToFront(_ id: String) {
        guard let openWindow else { return }
        bringToFront(id, openWindow: openWindow)
    }
}
