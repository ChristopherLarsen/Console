import SwiftUI

@MainActor
final class ConsoleWindowManager {
    static var openWindow: OpenWindowAction?

    /// Registered by MainWindowConfigurator — avoids fragile identifier matching.
    static weak var mainWindow: NSWindow?

    static func bringToFront(_ id: String, openWindow: OpenWindowAction) {
        NSApp.activate(ignoringOtherApps: true)

        func raise(_ window: NSWindow) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.orderFrontRegardless()
            window.makeKey()
        }

        if id == "main", let window = mainWindow {
            raise(window)
        } else if let existing = NSApp.windows.first(where: {
            $0.identifier?.rawValue.contains(id) == true
        }) {
            raise(existing)
        } else {
            openWindow(id: id)
            // One hop so SwiftUI has created the window before we raise it
            DispatchQueue.main.async {
                if let last = NSApp.windows.last {
                    raise(last)
                }
            }
        }
    }

    static func bringToFront(_ id: String) {
        guard let openWindow else { return }
        bringToFront(id, openWindow: openWindow)
    }
}
