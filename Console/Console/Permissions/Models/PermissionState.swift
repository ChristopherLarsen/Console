import Foundation


/// Runtime state of a single permission.
/// Combines static info with current authorization status.
struct PermissionState: Identifiable {
    /// The permission type this state represents
    let type: PermissionType
    
    /// Current authorization status from macOS
    var currentStatus: PermissionStatus
    
    /// When the status was last checked
    var lastChecked: Date
    
    /// Whether this permission can be revoked by the user
    /// (Some permissions like "restricted" cannot be changed by user)
    var isReversible: Bool {
        currentStatus.isUserChangeable
    }
    
    var id: String { type.id }
    
    /// Static info about this permission type
    var info: PermissionInfo {
        PermissionInfo.info(for: type)
    }
    
    /// Whether status is stale and should be refreshed (older than 5 seconds)
    var isStale: Bool {
        Date().timeIntervalSince(lastChecked) > 5.0
    }
    
    /// Create initial state with unknown status
    init(type: PermissionType, status: PermissionStatus = .notGranted) {
        self.type = type
        self.currentStatus = status
        self.lastChecked = Date()
    }
    
    /// Update status with new check result
    mutating func update(status: PermissionStatus) {
        self.currentStatus = status
        self.lastChecked = Date()
    }
    
    /// Create states for all permission types with default status
    static func allPermissions(defaultStatus: PermissionStatus = .notGranted) -> [PermissionState] {
        PermissionType.allCases.map { PermissionState(type: $0, status: defaultStatus) }
    }
}

// MARK: - Collection Helpers

extension Array where Element == PermissionState {
    /// Get state for a specific permission type
    func state(for type: PermissionType) -> PermissionState? {
        first { $0.type == type }
    }
    
    /// Get states for permissions in a specific group
    func states(in group: PermissionGroup) -> [PermissionState] {
        filter { $0.info.group == group }
    }
    
    /// Count of granted permissions
    var grantedCount: Int {
        filter { $0.currentStatus == .granted }.count
    }
    
    /// Summary string: "X of Y permissions granted"
    var summaryText: String {
        "\(grantedCount) of \(count) permissions granted"
    }
}
