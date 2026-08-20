import Foundation


/// Impact level indicating how powerful/sensitive a permission is.
enum PermissionImpactLevel: Int, Comparable {
    case low = 1      // Minimal data access
    case medium = 2   // Moderate access
    case high = 3     // Significant access (e.g., microphone)
    case critical = 4 // Full system access (e.g., accessibility)
    
    static func < (lhs: PermissionImpactLevel, rhs: PermissionImpactLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
    
    var displayLabel: String {
        switch self {
        case .low: return "Low Impact"
        case .medium: return "Medium Impact"
        case .high: return "High Impact"
        case .critical: return "High Impact"
        }
    }
}

/// Static information about a permission type.
/// Contains all metadata needed to display permission details in the UI.
struct PermissionInfo: Identifiable {
    let type: PermissionType
    let group: PermissionGroup
    let impactLevel: PermissionImpactLevel
    
    /// Full description of what this permission enables (user-facing)
    let whatItDoes: String
    
    /// When Console uses this permission (user-facing)
    let whenUsed: String
    
    var id: String { type.id }
    var name: String { type.displayName }
    var icon: String { type.icon }
    var shortDescription: String { type.shortDescription }
    
    /// All permission info instances, one per permission type
    static let all: [PermissionInfo] = [
        PermissionInfo(
            type: .microphone,
            group: .sensory,
            impactLevel: .high,
            whatItDoes: "Console can hear your voice so you can give spoken commands and have voice conversations.",
            whenUsed: "Only when you activate voice input or start a voice conversation."
        ),
        PermissionInfo(
            type: .accessibility,
            group: .systemControl,
            impactLevel: .critical,
            whatItDoes: "Console can control your Mac to help you automate tasks, click buttons, type text, and interact with apps on your behalf.",
            whenUsed: "When you ask Console to perform actions in apps or automate workflows."
        ),
        PermissionInfo(
            type: .automation,
            group: .systemControl,
            impactLevel: .critical,
            whatItDoes: "Console can work with other apps using AppleScript to automate complex workflows across multiple applications.",
            whenUsed: "When you ask Console to control other apps or run automated workflows."
        ),
        PermissionInfo(
            type: .speechRecognition,
            group: .sensory,
            impactLevel: .high,
            whatItDoes: "Console can transcribe your speech in real time using on-device recognition.",
            whenUsed: "Only when you enable live speech-to-text features."
        )
    ]
    
    /// Get info for a specific permission type
    static func info(for type: PermissionType) -> PermissionInfo {
        if let info = all.first(where: { $0.type == type }) {
            return info
        }
        printDebug("PermissionInfo: missing info for \(type.rawValue)")
        return PermissionInfo(
            type: type,
            group: PermissionGroup.group(for: type),
            impactLevel: .medium,
            whatItDoes: type.shortDescription,
            whenUsed: "When you enable this permission."
        )
    }
    
    /// Get all permissions in a specific group
    static func permissions(in group: PermissionGroup) -> [PermissionInfo] {
        all.filter { $0.group == group }
    }
}
