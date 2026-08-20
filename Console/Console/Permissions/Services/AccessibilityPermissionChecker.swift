import Foundation
import ApplicationServices
import AppKit


/// Checks Accessibility permission status on macOS.
/// Accessibility allows UI automation and control of other apps.
actor AccessibilityPermissionChecker {
    
    /// Check current Accessibility permission status without prompting.
    /// - Returns: Current permission status
    func checkStatus() -> PermissionStatus {
        // AXIsProcessTrusted returns true if the app has accessibility permission
        let isTrusted = AXIsProcessTrusted()
        return isTrusted ? .granted : .notGranted
    }
    
    /// Request Accessibility permission.
    /// This opens System Settings to the Accessibility pane with the app highlighted.
    /// Unlike other permissions, there's no system dialog - user must manually enable.
    /// - Returns: Whether permission is currently granted (won't change immediately)
    func requestAccess() async -> Bool {
        // AXIsProcessTrustedWithOptions with kAXTrustedCheckOptionPrompt opens
        // System Settings and highlights the app in the Accessibility list
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
    
    /// Open System Settings to Accessibility pane.
    func openSystemSettings() {
        // URL scheme to open Privacy & Security > Accessibility
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Convenience Extension

extension AccessibilityPermissionChecker {
    /// Check status and update the view model
    func checkAndUpdate(viewModel: PermissionsViewModel) async {
        let status = checkStatus()
        await MainActor.run {
            viewModel.updateStatus(for: .accessibility, status: status)
        }
    }
}
