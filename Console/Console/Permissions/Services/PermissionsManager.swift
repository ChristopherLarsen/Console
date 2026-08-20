import Foundation
import AVFoundation
import AppKit
import Speech


/// Manages permission requests across the app, coordinating status checks and modal presentation.
@MainActor @Observable
final class PermissionsManager {
    
    // MARK: - Observable State
    
    /// The permission type currently awaiting user action via modal. nil when no modal is shown.
    private(set) var pendingPermissionType: PermissionType?
    
    /// Convenience property for view layer to check if modal should be displayed.
    var isShowingPermissionModal: Bool {
        pendingPermissionType != nil
    }
    
    // MARK: - Private State
    
    /// Stored completion handler for the pending permission request.
    @ObservationIgnored
    private var pendingCompletion: ((Bool) -> Void)?
    
    // MARK: - Public API
    
    /// Request a permission, showing the modal if not already granted.
    /// - Parameters:
    ///   - type: The permission type required for the operation.
    ///   - completion: Called with `true` if permission is granted, `false` otherwise.
    func requirePermission(_ type: PermissionType, completion: @escaping (Bool) -> Void) {
        // Check if permission is already granted
        let currentStatus = checkPermissionStatus(type)
        
        if currentStatus == .granted {
            // Permission already granted, proceed immediately
            completion(true)
            return
        }
        
        // Permission not granted - show modal and store completion for later
        pendingCompletion = completion
        pendingPermissionType = type
    }
    
    /// Called by the UI when user taps "Grant Permission" in the modal.
    /// Requests the actual system permission and calls the stored completion.
    func handleGrant() async {
        guard let type = pendingPermissionType else { return }
        
        // Request the actual system permission
        let granted = await requestPermission(type)
        
        // Capture completion before clearing state
        let completion = pendingCompletion
        
        // Clear pending state
        pendingPermissionType = nil
        pendingCompletion = nil
        
        // Call completion with result
        completion?(granted)
    }
    
    /// Called by the UI when user dismisses the modal without granting.
    func handleDismiss() {
        // Capture completion before clearing state
        let completion = pendingCompletion
        
        // Clear pending state
        pendingPermissionType = nil
        pendingCompletion = nil
        
        // Call completion with false (permission not granted)
        completion?(false)
    }
    
    // MARK: - Permission Status Checking
    
    /// Check current status for a permission type without prompting.
    /// - Parameter type: The permission type to check.
    /// - Returns: Current permission status.
    func checkPermissionStatus(_ type: PermissionType) -> PermissionStatus {
        switch type {
        case .microphone:
            return mapAVAuthorizationStatus(AVCaptureDevice.authorizationStatus(for: .audio))
            
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notGranted
            
        case .automation:
            return AutomationPermissionChecker.checkStatus()
            
        case .speechRecognition:
            return mapSFAuthorizationStatus(SFSpeechRecognizer.authorizationStatus())
        }
    }
    
    // MARK: - Permission Requesting
    
    /// Request a specific permission from the system.
    /// - Parameter type: The permission type to request.
    /// - Returns: Whether the permission was granted.
    private func requestPermission(_ type: PermissionType) async -> Bool {
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
    
    // MARK: - Helpers
    
    private func mapAVAuthorizationStatus(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .notDetermined:
            return .notGranted
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        case .authorized:
            return .granted
        @unknown default:
            return .notGranted
        }
    }
    
    private func mapSFAuthorizationStatus(_ status: SFSpeechRecognizerAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .notDetermined:
            return .notGranted
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        case .authorized:
            return .granted
        @unknown default:
            return .notGranted
        }
    }
    
    private func openSystemSettings(for type: PermissionType) {
        let urlString: String
        switch type {
        case .microphone:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .accessibility:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .automation:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        case .speechRecognition:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
        }
        
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
