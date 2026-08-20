import SwiftUI


/// The current authorization status of a permission.
/// Maps to macOS authorization states with user-friendly presentation.
enum PermissionStatus: String, CaseIterable, Identifiable {
    /// User has not yet been asked or has not granted permission
    case notGranted
    
    /// User has explicitly granted permission
    case granted
    
    /// Permission is restricted by system policy (parental controls, MDM, etc.)
    case restricted
    
    /// User has explicitly denied permission
    case denied
    
    var id: String { rawValue }
    
    /// Human-readable label for display
    var displayLabel: String {
        switch self {
        case .notGranted: return "Not Granted"
        case .granted: return "Granted"
        case .restricted: return "Restricted"
        case .denied: return "Denied"
        }
    }
    
    /// Color for status indicator
    var indicatorColor: Color {
        switch self {
        case .notGranted: return .gray
        case .granted: return .green
        case .restricted: return .yellow
        case .denied: return .red
        }
    }
    
    /// SF Symbol for status indicator
    var indicatorIcon: String {
        switch self {
        case .notGranted: return "circle"
        case .granted: return "checkmark.circle.fill"
        case .restricted: return "exclamationmark.triangle.fill"
        case .denied: return "xmark.circle.fill"
        }
    }
    
    /// Whether the user can change this status (restricted cannot be changed by user)
    var isUserChangeable: Bool {
        switch self {
        case .notGranted, .granted, .denied: return true
        case .restricted: return false
        }
    }
    
    /// Primary action button label for this status
    var actionLabel: String {
        switch self {
        case .notGranted: return "Grant"
        case .granted: return "Manage"
        case .restricted: return "View Details"
        case .denied: return "Grant"
        }
    }
}
