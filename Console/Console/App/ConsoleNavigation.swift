import Foundation

/// Helpers for opening main-window destinations from menu bar, voice commands, and overlays.
enum ConsoleNavigation {
    static let sidebarKey = "sidebarSelection"
    static let tabKey = "tabSelection"
    static let terminalExpandedKey = "isTerminalExpanded"

    /// Show a primary sidebar destination.
    /// `.terminal` expands the bottom Terminal panel instead of changing the center page.
    static func show(_ selection: SidebarSelection) {
        if selection == .terminal {
            UserDefaults.standard.set(true, forKey: terminalExpandedKey)
            UserDefaults.standard.synchronize()
            return
        }

        UserDefaults.standard.set(selection.rawValue, forKey: sidebarKey)
        // Keep legacy tabSelection in sync for callers that still observe it.
        switch selection {
        case .triggers:
            UserDefaults.standard.set(TabSelection.triggers.rawValue, forKey: tabKey)
        case .commands:
            UserDefaults.standard.set(TabSelection.myCommands.rawValue, forKey: tabKey)
        case .settings:
            UserDefaults.standard.set(TabSelection.settings.rawValue, forKey: tabKey)
        case .terminal:
            break
        case .home, .aiProvider, .jira:
            break
        }
        UserDefaults.standard.synchronize()
    }

    /// Show Triggers or Commands (legacy helper used by menu bar / voice actions).
    static func showTerminal(tab: TabSelection = .triggers) {
        switch tab {
        case .triggers:
            show(.triggers)
        case .myCommands:
            show(.commands)
        case .live:
            show(.terminal)
        case .settings:
            show(.settings)
        }
    }

    /// Show the Settings sidebar item.
    static func showSettings() {
        show(.settings)
    }

    /// Show the AI Provider sidebar item.
    static func showAIProvider() {
        show(.aiProvider)
    }

    /// Show the Home sidebar item.
    static func showHome() {
        show(.home)
    }
}
