import SwiftUI

/// Sidebar navigation selection for the main window.
enum SidebarSelection: String, CaseIterable, Identifiable {
    case home
    case jira
    case mergeRequests
    case triggers
    case commands
    case aiProvider
    case terminal
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: return "Home"
        case .jira: return "JIRA"
        case .mergeRequests: return "Merge Requests"
        case .triggers: return "Triggers"
        case .commands: return "Commands"
        case .aiProvider: return "AI Provider"
        case .terminal: return "Terminal"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .jira: return "j.square"
        case .mergeRequests: return "arrow.triangle.merge"
        case .triggers: return "waveform"
        case .commands: return "list.bullet.rectangle"
        case .aiProvider: return "brain"
        case .terminal: return "terminal"
        case .settings: return "gear"
        }
    }
}
