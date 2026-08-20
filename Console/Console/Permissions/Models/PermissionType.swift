import Foundation


/// All permission types that Console can request from the user.
/// Each type corresponds to a macOS Privacy & Security setting.
enum PermissionType: String, CaseIterable, Identifiable {
    /// Microphone - allows audio input capture
    /// macOS API: AVCaptureDevice.authorizationStatus(for: .audio)
    case microphone
    
    /// Accessibility - allows UI automation and control
    /// macOS API: AXIsProcessTrusted()
    case accessibility
    
    /// AppleScript/Automation - allows controlling other apps via scripting
    /// macOS API: NSAppleScript permissions, System Events access
    case automation
    
    /// Speech Recognition - allows on-device speech-to-text
    /// macOS API: SFSpeechRecognizer.authorizationStatus()
    case speechRecognition
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        case .automation: return "App Automation"
        case .speechRecognition: return "Speech Recognition"
        }
    }
    
    var icon: String {
        switch self {
        case .microphone: return "mic"
        case .accessibility: return "accessibility"
        case .automation: return "applescript"
        case .speechRecognition: return "waveform"
        }
    }
    
    var shortDescription: String {
        switch self {
        case .microphone:
            return "Console can hear your voice"
        case .accessibility:
            return "Console can control your Mac"
        case .automation:
            return "Console can work with other apps"
        case .speechRecognition:
            return "Console can understand your speech"
        }
    }
    
    var detailedDescription: String {
        switch self {
        case .microphone:
            return "Allows Console to listen to your voice commands. " +
                   "You can speak naturally instead of typing, making interactions faster and more convenient."
        case .accessibility:
            return "Allows Console to help you control your Mac hands-free. " +
                   "Console can click buttons, type text, and navigate apps on your behalf when you ask."
        case .automation:
            return "Allows Console to automate other apps on your Mac. " +
                   "This enables powerful workflows that span multiple applications to save you time."
        case .speechRecognition:
            return "Allows Console to transcribe your speech in real time using on-device recognition. " +
                   "This enables live captions and voice-driven interactions."
        }
    }
    
    var systemSettingsURL: URL? {
        let baseURL = "x-apple.systempreferences:com.apple.preference.security"
        let privacyAnchor: String?
        
        switch self {
        case .microphone:
            privacyAnchor = "Privacy_Microphone"
        case .accessibility:
            privacyAnchor = "Privacy_Accessibility"
        case .automation:
            privacyAnchor = "Privacy_Automation"
        case .speechRecognition:
            privacyAnchor = "Privacy_SpeechRecognition"
        }
        
        guard let anchor = privacyAnchor else { return nil }
        return URL(string: "\(baseURL)?\(anchor)")
    }
    
    var revokeConsequences: String {
        switch self {
        case .microphone:
            return "Voice input and dictation won't be available. You can still type messages and use all other features normally."
        case .accessibility:
            return "Console won't be able to click, type, or navigate apps for you. You can still get guidance and instructions to do these actions yourself."
        case .automation:
            return "Console won't be able to control other apps directly. You can still get step-by-step instructions for tasks."
        case .speechRecognition:
            return "Live speech transcription won't be available. You can still type messages and use all other features normally."
        }
    }
    
    var grantInstructions: [String] {
        switch self {
        case .microphone:
            return [
                "Click \"Continue\" below",
                "macOS will show a permission dialog",
                "Click \"OK\" to allow microphone access",
                "Return to this window when finished"
            ]
        case .accessibility:
            return [
                "Click \"Continue\" below",
                "System Settings will open to Privacy & Security",
                "Find \"Accessibility\" in the list",
                "Turn on the switch next to Console",
                "Return to this window when finished"
            ]
        case .automation:
            return [
                "Click \"Grant Permission\" below",
                "macOS will ask to let Console control System Events",
                "Click \"OK\" to allow App Automation",
                "If you previously denied this, enable Console under System Settings → Automation",
                "Return to this window when finished"
            ]
        case .speechRecognition:
            return [
                "Click \"Continue\" below",
                "macOS will show a speech recognition permission dialog",
                "Click \"Allow\" to enable speech recognition",
                "Return to this window when finished"
            ]
        }
    }

    /// Caption under the grant button describing what happens next.
    var grantButtonExplanation: String {
        switch self {
        case .microphone, .speechRecognition:
            return "Clicking \"Grant Permission\" will show a system permission dialog"
        case .accessibility:
            return "Clicking \"Grant Permission\" will open System Settings"
        case .automation:
            return "Clicking \"Grant Permission\" will ask macOS to let Console control other apps"
        }
    }

    var grantedCapabilities: String {
        switch self {
        case .microphone:
            return "use voice commands and dictation"
        case .accessibility:
            return "have Console control your Mac on your behalf"
        case .automation:
            return "automate tasks across multiple apps"
        case .speechRecognition:
            return "use live speech transcription"
        }
    }
}
