import Foundation
import AVFoundation
import AppKit


/// Checks Microphone permission status on macOS.
/// Microphone allows audio input capture for voice commands.
actor MicrophonePermissionChecker {
    
    /// Check current Microphone permission status without prompting.
    /// - Returns: Current permission status
    func checkStatus() -> PermissionStatus {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return mapAuthorizationStatus(status)
    }
    
    /// Request Microphone permission.
    /// This will show the system permission dialog if not yet determined.
    /// - Returns: Whether permission was granted after request
    func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
    
    /// Open System Settings to Microphone pane.
    func openSystemSettings() {
        // URL scheme to open Privacy & Security > Microphone
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
    
    // MARK: - Private
    
    private func mapAuthorizationStatus(_ status: AVAuthorizationStatus) -> PermissionStatus {
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
}

// MARK: - Convenience Extension

extension MicrophonePermissionChecker {
    /// Check status and update the view model
    func checkAndUpdate(viewModel: PermissionsViewModel) async {
        let status = checkStatus()
        await MainActor.run {
            viewModel.updateStatus(for: .microphone, status: status)
        }
    }
}
