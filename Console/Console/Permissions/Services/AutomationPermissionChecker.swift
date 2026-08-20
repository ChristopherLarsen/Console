import Foundation
import AppKit
import ApplicationServices

/// Checks and requests Apple Events / Automation permission.
///
/// Automation is granted per target app. Console uses System Events as the probe
/// target because most voice commands send Apple Events there. Status checks never
/// prompt; `requestAccess()` sends an Apple Event so macOS shows the consent dialog
/// and registers Console in System Settings → Privacy & Security → Automation.
enum AutomationPermissionChecker {
    private static let systemEventsBundleID = "com.apple.systemevents"

    /// AppleScript "not allowed to send Apple events"
    private static let appleEventNotPermitted = -1743
    /// AppleScript "a privilege violation occurred"
    private static let privilegeViolation = -10004
    /// `errAEEventWouldRequireUserConsent` — not determined, prompt suppressed
    private static let wouldRequireUserConsent: OSStatus = -1744
    /// Target process is not running
    private static let processNotFound: OSStatus = Int32(procNotFound)

    /// Current Automation permission for System Events, without showing a prompt.
    @MainActor
    static func checkStatus() -> PermissionStatus {
        permissionStatus(prompt: false)
    }

    /// Request Automation permission by sending an Apple Event to System Events.
    /// Opens System Settings only when the user has already denied consent (the
    /// system dialog will not appear again until they change it there).
    /// - Returns: Whether System Events automation is granted after the request.
    @MainActor
    static func requestAccess() -> Bool {
        switch permissionStatus(prompt: false) {
        case .granted:
            return true
        case .denied:
            openAutomationSettings()
            return false
        default:
            break
        }

        if sendSystemEventsProbe() {
            return true
        }

        if permissionStatus(prompt: false) == .denied {
            openAutomationSettings()
        }
        return false
    }

    /// Open System Settings to Privacy & Security → Automation.
    @MainActor
    static func openSystemSettings() {
        openAutomationSettings()
    }

    // MARK: - Private

    @MainActor
    private static func permissionStatus(prompt: Bool) -> PermissionStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: systemEventsBundleID)
        guard let aeDesc = target.aeDesc else {
            return .notGranted
        }

        let status = AEDeterminePermissionToAutomateTarget(
            aeDesc,
            typeWildCard,
            typeWildCard,
            prompt
        )
        return mapAppleEventStatus(status)
    }

    @MainActor
    private static func sendSystemEventsProbe() -> Bool {
        let script = """
        tell application "System Events"
            return name of first process
        end tell
        """

        var error: NSDictionary?
        let appleScript = NSAppleScript(source: script)
        let result = appleScript?.executeAndReturnError(&error)
        return result != nil && error == nil
    }

    @MainActor
    private static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func mapAppleEventStatus(_ status: OSStatus) -> PermissionStatus {
        switch status {
        case noErr:
            return .granted
        case OSStatus(appleEventNotPermitted), OSStatus(privilegeViolation):
            return .denied
        case wouldRequireUserConsent, processNotFound:
            return .notGranted
        default:
            return .notGranted
        }
    }
}

extension AutomationPermissionChecker {
    @MainActor
    static func checkAndUpdate(viewModel: PermissionsViewModel) {
        viewModel.updateStatus(for: .automation, status: checkStatus())
    }
}
