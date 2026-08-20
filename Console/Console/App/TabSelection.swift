import SwiftUI

enum TabSelection: String, CaseIterable, Identifiable {
    case triggers
    case myCommands
    case live
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .triggers: return "Triggers"
        case .myCommands: return "Commands"
        case .live: return "Live"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .triggers: return "waveform"
        case .myCommands: return "list.bullet.rectangle"
        case .live: return "dot.radiowaves.left.and.right"
        case .settings: return "gear"
        }
    }
}
