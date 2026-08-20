import Foundation


/// Permission categories for grouping in the UI.
/// Ordered by impact level: most powerful permissions first.
enum PermissionGroup: String, CaseIterable, Identifiable {
    /// System Control - permissions that allow controlling the Mac
    /// Includes: Accessibility, Automation
    case systemControl
    
    /// Sensory - permissions that capture audio input
    /// Includes: Microphone, Speech Recognition
    case sensory
    
    var id: String { rawValue }
    
    /// Human-readable group name for section headers
    var displayName: String {
        switch self {
        case .systemControl: return "System Control"
        case .sensory: return "Sensory Access"
        }
    }
    
    /// Brief description of what this group covers
    var description: String {
        switch self {
        case .systemControl:
            return "Permissions that let Console control your Mac"
        case .sensory:
            return "Permissions that let Console see and hear"
        }
    }
    
    /// SF Symbol for the group
    var icon: String {
        switch self {
        case .systemControl: return "gearshape.2"
        case .sensory: return "eye"
        }
    }
    
    /// Permission types that belong to this group
    var permissionTypes: [PermissionType] {
        switch self {
        case .systemControl:
            return [.accessibility, .automation]
        case .sensory:
            return [.microphone, .speechRecognition]
        }
    }
    
    /// Returns the group for a given permission type
    static func group(for type: PermissionType) -> PermissionGroup {
        switch type {
        case .accessibility, .automation:
            return .systemControl
        case .microphone, .speechRecognition:
            return .sensory
        }
    }
}
