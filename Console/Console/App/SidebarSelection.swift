import SwiftUI

/// Sidebar navigation selection for the main window.
enum SidebarSelection: String, CaseIterable, Identifiable {
    case home
    case brief
    case toDo
    case jira
    case mergeRequests
    case commands
    case aiProvider
    case sessions
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: return "Home"
        case .brief: return "Brief"
        case .toDo: return "To Do"
        case .jira: return "JIRA"
        case .mergeRequests: return "GitLab"
        case .commands: return "Commands"
        case .aiProvider: return "AI Provider"
        case .sessions: return "Sessions"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .brief: return "sun.max"
        case .toDo: return "checklist"
        case .jira: return "j.square"
        case .mergeRequests: return "arrow.triangle.merge"
        case .commands: return "list.bullet.rectangle"
        case .aiProvider: return "brain"
        case .sessions: return "terminal"
        case .settings: return "gear"
        }
    }
}
