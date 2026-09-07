import SwiftUI
import AppKit


/// Observes permission status changes at the app level.
/// Polls permission statuses while the app is active to detect external changes
/// (e.g., user disabling a permission in System Settings).
@Observable
@MainActor
final class PermissionBackgroundObserver {
    
    /// The shared ViewModel that holds permission states
    private(set) var viewModel: PermissionsViewModel
    
    /// Whether the observer is currently polling
    private(set) var isActive: Bool = false
    
    /// Tracks permissions that were revoked during this session (for notifications)
    private(set) var recentlyRevokedPermissions: [PermissionType] = []
    
    /// Previous permission states for change detection
    private var previousStates: [PermissionType: PermissionStatus] = [:]
    
    /// Notification observers for app lifecycle events
    private var activeObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?

    /// Periodic revocation-detection loop for the current active cycle.
    private var changeDetectionTask: Task<Void, Never>?
    
    private var appTerminatedObserver: NSObjectProtocol?
    
    /// Bundle ID for System Settings (macOS 13+) and System Preferences (older)
    private let systemSettingsBundleIDs = [
        "com.apple.systempreferences",      // macOS 12 and earlier
        "com.apple.SystemPreferences"       // macOS 13+ (Ventura)
    ]
    
    // MARK: - Initialization
    
    init() {
        self.viewModel = PermissionsViewModel()
    }
    
    // MARK: - Lifecycle
    
    /// Start observing app lifecycle and permission changes.
    /// Call this once when the app launches.
    func startObserving() {
        guard activeObserver == nil else { return }
        
        // Store initial states for change detection
        captureCurrentStates()
        
        // Observe app becoming active (foreground)
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.handleAppBecameActive()
            }
        }
        
        // Observe app going to background
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.handleAppWillResignActive()
            }
        }
        
        // User may have changed permissions while System Settings was open.
        appTerminatedObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier else { return }
            
            Task { @MainActor [weak self] in
                self?.handleAppTerminated(bundleID: bundleID)
            }
        }
        
        // Start polling immediately if app is active
        if NSApplication.shared.isActive {
            handleAppBecameActive()
        }
    }
    
    /// Stop observing app lifecycle and permission changes.
    /// Call this when the observer should be deallocated.
    func stopObserving() {
        if let observer = activeObserver {
            NotificationCenter.default.removeObserver(observer)
            activeObserver = nil
        }
        if let observer = resignObserver {
            NotificationCenter.default.removeObserver(observer)
            resignObserver = nil
        }
        if let observer = appTerminatedObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appTerminatedObserver = nil
        }

        changeDetectionTask?.cancel()
        changeDetectionTask = nil

        viewModel.stopPolling()
        isActive = false
    }
    
    /// Clear the list of recently revoked permissions.
    /// Call this after showing a notification or alert.
    func clearRevokedPermissions() {
        recentlyRevokedPermissions.removeAll()
    }
    
    /// Dismiss a specific revoked permission from the list.
    func dismissRevokedPermission(_ type: PermissionType) {
        recentlyRevokedPermissions.removeAll { $0 == type }
    }
    
    // MARK: - Private
    
    private func handleAppBecameActive() {
        guard !isActive else { return }
        isActive = true
        
        // Capture states before polling to detect changes
        captureCurrentStates()
        
        // Start polling with change detection
        viewModel.startPolling()
        
        // Schedule periodic change detection
        scheduleChangeDetection()
    }
    
    private func handleAppWillResignActive() {
        guard isActive else { return }
        isActive = false

        changeDetectionTask?.cancel()
        changeDetectionTask = nil

        viewModel.stopPolling()
    }
    
    /// Handle when an app terminates - if it's System Settings, refresh permissions immediately.
    private func handleAppTerminated(bundleID: String) {
        guard systemSettingsBundleIDs.contains(bundleID) else { return }
        
        // System Settings was closed - user may have changed permissions
        // Trigger immediate refresh and revocation detection
        Task {
            await viewModel.refreshAllStatuses()
            await detectRevocations()
        }
    }
    
    /// Capture current permission states for change comparison.
    private func captureCurrentStates() {
        for state in viewModel.permissionStates {
            previousStates[state.type] = state.currentStatus
        }
    }
    
    /// Schedule periodic checks for permission revocations.
    /// Cancels any previous cycle's loop so rapid active/resign/active
    /// transitions cannot stack parallel detection tasks.
    private func scheduleChangeDetection() {
        changeDetectionTask?.cancel()
        changeDetectionTask = Task {
            // Wait for polling to update states
            try? await Task.sleep(nanoseconds: 6_000_000_000) // 6 seconds (after first poll)

            while !Task.isCancelled && isActive {
                await detectRevocations()
                try? await Task.sleep(nanoseconds: 5_000_000_000) // Check every 5 seconds
            }
        }
    }
    
    /// Detect any permissions that were revoked since last check.
    private func detectRevocations() async {
        for state in viewModel.permissionStates {
            let previousStatus = previousStates[state.type]
            let currentStatus = state.currentStatus
            
            // Detect revocation: was granted, now not granted
            if previousStatus == .granted && currentStatus == .notGranted {
                if !recentlyRevokedPermissions.contains(state.type) {
                    recentlyRevokedPermissions.append(state.type)
                }
            }
            
            // Update previous state
            previousStates[state.type] = currentStatus
        }
    }
}
