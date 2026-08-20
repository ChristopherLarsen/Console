import Foundation

enum ListeningState: String, CaseIterable {
    case off
    case passive
    case commandListening
    case awaitingAuthorization
    case executing

    var menuBarIcon: String {
        switch self {
        case .off:
            return "buddy_disabled"
        case .passive:
            return "buddy_enabled"
        case .commandListening, .executing, .awaitingAuthorization:
            return "buddy_listening"
        }
    }

    var displayLabel: String {
        switch self {
        case .off: return "Off"
        case .passive: return "Listening"
        case .commandListening: return "Hearing Command"
        case .awaitingAuthorization: return "Awaiting Authorization"
        case .executing: return "Executing"
        }
    }

    var isActive: Bool {
        self != .off
    }
}
