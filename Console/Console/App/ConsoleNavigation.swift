import Foundation

/// Helpers for opening main-window destinations from menu bar, voice commands, and overlays.
enum ConsoleNavigation {
    static let sidebarKey = "sidebarSelection"
    static let tabKey = "tabSelection"
    /// Expansion preference for the global bottom zsh Terminal drawer.
    /// Unrelated to the Sessions destination, which owns Claude PTYs.
    static let terminalExpandedKey = "isTerminalExpanded"

    /// Conservative migration from the pre-Sessions era: a stored sidebar
    /// `"terminal"` was never a real page, so map it to Home and expand the
    /// global bottom Terminal drawer. The drawer preference is preserved.
    static func migrateLegacyTerminalNavigation() {
        if UserDefaults.standard.string(forKey: sidebarKey) == "terminal" {
            UserDefaults.standard.set(SidebarSelection.home.rawValue, forKey: sidebarKey)
            setTerminalExpanded(true)
        }
    }

    /// Show a primary sidebar destination.
    static func show(_ selection: SidebarSelection) {
        UserDefaults.standard.set(selection.rawValue, forKey: sidebarKey)
        // Keep legacy tabSelection in sync for callers that still observe it.
        switch selection {
        case .triggers:
            UserDefaults.standard.set(TabSelection.triggers.rawValue, forKey: tabKey)
        case .commands:
            UserDefaults.standard.set(TabSelection.myCommands.rawValue, forKey: tabKey)
        case .settings:
            UserDefaults.standard.set(TabSelection.settings.rawValue, forKey: tabKey)
        case .sessions, .home, .next, .brief, .aiProvider, .jira, .ticketWork, .mergeRequests:
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
            expandTerminal()
        case .settings:
            show(.settings)
        }
    }

    /// Expand the global bottom zsh Terminal drawer without changing pages.
    /// Sessions remains reachable through `showSessions()`.
    static func expandTerminal() {
        setTerminalExpanded(true)
    }

    private static func setTerminalExpanded(_ expanded: Bool) {
        UserDefaults.standard.set(expanded, forKey: terminalExpandedKey)
        UserDefaults.standard.synchronize()
    }

    /// Show the Sessions sidebar item.
    static func showSessions() {
        show(.sessions)
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

    // MARK: - Sidebar hotkeys (⌃1…⌃9, ⌃0)

    /// Sidebar destinations addressed by ⌃1…⌃9 plus ⌃0, in visible sidebar
    /// order. Settings deliberately has no number.
    static let sidebarHotkeyDestinations: [SidebarSelection] = [
        .home, .next, .brief, .jira, .ticketWork,
        .sessions, .mergeRequests, .triggers, .commands,
        .aiProvider
    ]

    /// The sidebar destination targeted by ⌃N (⌃0 selects the tenth item);
    /// nil when N has no destination.
    static func sidebarDestination(hotkeyNumber number: Int) -> SidebarSelection? {
        guard number >= 0, number <= 9, number != 10 else { return nil }
        let index = number == 0 ? 9 : number - 1
        guard sidebarHotkeyDestinations.indices.contains(index) else { return nil }
        return sidebarHotkeyDestinations[index]
    }

    /// The keyboard character for a hotkey offset: ⌃1…⌃9, then ⌃0 for the
    /// tenth destination.
    static func hotkeyKeyCharacter(forOffset offset: Int) -> String {
        offset < 9 ? "\(offset + 1)" : "0"
    }

    // MARK: - Session hotkeys (⌘1…⌘9)

    /// Highest session hotkey number (Cmd+1…Cmd+9).
    static let maxSessionHotkeyNumber = 9

    /// The session targeted by the ⌃N session hotkey: the Nth session in
    /// store order, or nil when no session corresponds to that number.
    /// Pure so the mapping stays unit-testable without live sessions.
    static func hotkeySessionID(number: Int, in sessions: [ConsoleSession]) -> UUID? {
        guard number >= 1, number <= maxSessionHotkeyNumber else { return nil }
        guard sessions.indices.contains(number - 1) else { return nil }
        return sessions[number - 1].id
    }
}
