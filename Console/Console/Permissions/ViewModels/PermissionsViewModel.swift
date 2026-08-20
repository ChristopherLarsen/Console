import SwiftUI
import Observation
import AVFoundation
import AppKit
import Speech

/// Central ViewModel for managing all permission states.
/// Observable for reactive UI updates across the permissions system.
@Observable
@MainActor
final class PermissionsViewModel {
    /// Current state of all permissions
    private(set) var permissionStates: [PermissionState]
    
    /// Whether a status refresh is in progress
    private(set) var isRefreshing: Bool = false
    
    /// Error message if last operation failed
    private(set) var errorMessage: String?
    
    /// Whether the error alert should be shown
    var showError: Bool = false
    
    /// Status poller for detecting external permission changes
    private let statusPoller = PermissionStatusPoller()
    
    /// Whether polling is currently active
    private(set) var isPollingActive: Bool = false
    
    // MARK: - Computed Properties
    
    /// Count of granted permissions
    var grantedCount: Int {
        permissionStates.grantedCount
    }
    
    /// Total number of permissions
    var totalCount: Int {
        permissionStates.count
    }
    
    /// Whether all permissions have been granted
    var allGranted: Bool {
        grantedCount == totalCount && totalCount > 0
    }
    
    /// Summary text: "X of Y permissions granted"
    var summaryText: String {
        permissionStates.summaryText
    }
    
    /// Permissions grouped by category
    var permissionsByGroup: [(group: PermissionGroup, states: [PermissionState])] {
        PermissionGroup.allCases.compactMap { group in
            let states = permissionStates.states(in: group)
            return states.isEmpty ? nil : (group, states)
        }
    }
    
    // MARK: - Initialization
    
    init() {
        // Initialize with all permissions in notGranted state
        self.permissionStates = PermissionState.allPermissions()
    }
    
    // MARK: - Public Methods
    
    /// Get state for a specific permission type
    func state(for type: PermissionType) -> PermissionState? {
        permissionStates.state(for: type)
    }
    
    /// Start real-time status polling.
    /// Call when permissions view appears or app becomes active.
    func startPolling() {
        guard !isPollingActive else { return }
        isPollingActive = true
        Task {
            await statusPoller.start(viewModel: self)
        }
    }
    
    /// Stop real-time status polling.
    /// Call when permissions view disappears or app goes to background.
    func stopPolling() {
        guard isPollingActive else { return }
        isPollingActive = false
        Task {
            await statusPoller.stop()
        }
    }
    
    /// Called when the permissions view appears.
    /// Starts polling and refreshes any stale cached statuses.
    func onViewAppear() {
        startPolling()
        Task {
            await refreshStaleStatuses()
        }
    }
    
    /// Called when the permissions view disappears.
    /// Stops polling to conserve resources.
    func onViewDisappear() {
        stopPolling()
    }
    
    /// Refresh status for all permissions (immediate, one-time check)
    /// Called on view appear and when app returns to foreground
    func refreshAllStatuses() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        errorMessage = nil
        
        // Run all status checks on background actor via the poller
        // Each check hops to the PermissionStatusPoller actor (off main thread)
        await withTaskGroup(of: Void.self) { group in
            for type in PermissionType.allCases {
                group.addTask {
                    await self.statusPoller.checkStatus(for: type, viewModel: self)
                }
            }
        }
        
        isRefreshing = false
    }
    
    /// Refresh only stale statuses (cached longer than 5 seconds).
    /// More efficient than refreshAllStatuses when cache is still fresh.
    func refreshStaleStatuses() async {
        guard !isRefreshing else { return }
        
        let staleTypes = permissionStates.filter { $0.isStale }.map { $0.type }
        guard !staleTypes.isEmpty else { return }
        
        isRefreshing = true
        errorMessage = nil
        
        // Only refresh permissions with stale cache
        await withTaskGroup(of: Void.self) { group in
            for type in staleTypes {
                group.addTask {
                    await self.statusPoller.checkStatus(for: type, viewModel: self)
                }
            }
        }
        
        isRefreshing = false
    }
    
    /// Refresh status for a single permission
    func refreshStatus(for type: PermissionType) async {
        await statusPoller.checkStatus(for: type, viewModel: self)
    }
    
    /// Update the status of a permission (called after status check completes)
    func updateStatus(for type: PermissionType, status: PermissionStatus) {
        guard let index = permissionStates.firstIndex(where: { $0.type == type }) else { return }
        permissionStates[index].update(status: status)
    }
    
    /// Get the current status of a specific permission.
    func permissionStatus(for type: PermissionType) -> PermissionStatus {
        for state in permissionStates {
            if state.type == type {
                return state.currentStatus
            }
        }
        return .notGranted
    }
    
    /// Request a permission grant, triggering the system prompt or opening System Settings.
    func requestPermission(_ type: PermissionType) async {
        _ = await performSystemPermissionRequest(type)
        await refreshStatus(for: type)
    }
    
    /// Open System Settings to the relevant permission pane.
    func openSystemSettings(for type: PermissionType) {
        if let url = type.systemSettingsURL {
            NSWorkspace.shared.open(url)
        }
    }
    
    // MARK: - System Permission Requests
    
    private func performSystemPermissionRequest(_ type: PermissionType) async -> Bool {
        switch type {
        case .microphone:
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            if status == .denied {
                openSystemSettings(for: type)
                return false
            }
            return await AVCaptureDevice.requestAccess(for: .audio)
            
        case .accessibility:
            openSystemSettings(for: type)
            return AXIsProcessTrusted()
            
        case .automation:
            return AutomationPermissionChecker.requestAccess()
            
        case .speechRecognition:
            let currentStatus = SFSpeechRecognizer.authorizationStatus()
            if currentStatus == .denied {
                openSystemSettings(for: type)
                return false
            }
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func setError(_ message: String) {
        errorMessage = message
        showError = true
    }
}
