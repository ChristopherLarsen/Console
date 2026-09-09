import SwiftUI

class AppSettings {
    @AppStorage("theme") var theme: AppTheme = .systemDefault
    @AppStorage("alwaysOnTop") var alwaysOnTop: Bool = false

    /// Start URL for the embedded JIRA WebView sidebar page.
    @AppStorage("webViewJiraURL") var webViewJiraURL: String = ""

    /// Start URL for the embedded Merge Requests WebView sidebar page.
    /// Legacy key; preserved so existing configurations keep working.
    @AppStorage("webViewMergeRequestsURL") var webViewMergeRequestsURL: String = ""

    // GitLab panel list URLs (Panel 3 reviews / Panel 4 authored).
    static let webViewGitLabReviewsURLKey = "webViewGitLabReviewsURL"
    static let webViewGitLabMyMergeRequestsURLKey = "webViewGitLabMyMergeRequestsURL"
    static let webViewMergeRequestsURLLegacyKey = "webViewMergeRequestsURL"

    // Terminal drawer settings
    /// Folder where new Terminal sessions start. Supports "~" for the home
    /// directory. Defaults to the user's home directory.
    static let defaultTerminalFolderKey = "defaultTerminalFolder"
    static let defaultTerminalFolderDefault = "~"

    /// Expands the stored terminal folder setting to a real start directory,
    /// falling back to the home directory when unset, empty, or missing.
    static func resolvedTerminalStartDirectory(from stored: String?) -> String {
        let trimmed = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return NSHomeDirectory() }
        let expanded = (trimmed as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return expanded
        }
        return NSHomeDirectory()
    }

    @AppStorage(AppSettings.webViewGitLabReviewsURLKey) var webViewGitLabReviewsURL: String = ""
    @AppStorage(AppSettings.webViewGitLabMyMergeRequestsURLKey) var webViewGitLabMyMergeRequestsURL: String = ""

    // Automation settings (Phase 0.3)
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false
    @AppStorage("listenOnStartup") var listenOnStartup: Bool = true
    @AppStorage("soundFeedbackEnabled") var soundFeedbackEnabled: Bool = true
    @AppStorage("visualFeedbackEnabled") var visualFeedbackEnabled: Bool = true
    @AppStorage("selectedAIProvider") var selectedAIProvider: String = AIProvider.none.rawValue
    @AppStorage("confidenceLevel") var confidenceLevel: String = ConfidenceLevel.normal.rawValue

    var confidenceThreshold: Double {
        ConfidenceLevel(rawValue: confidenceLevel)?.threshold ?? 0.75
    }
    @AppStorage("commandFailureBehavior") var commandFailureBehavior: String = CommandFailureBehavior.stopOnError.rawValue
    @AppStorage("catalogAssistedGeneration") var catalogAssistedGeneration: Bool = true
    @AppStorage("enableBuiltInCommands") var enableBuiltInCommands: Bool = true
    @AppStorage("noteFormattingEnabled") var noteFormattingEnabled: Bool = false

    // Authorization settings
    @AppStorage("requireConfirmationForDangerous") var requireConfirmationForDangerous: Bool = true
    @AppStorage("voiceOnlyAuthorization") var voiceOnlyAuthorization: Bool = true

    /// Require authorization for ALL commands (overrides sensitive-only mode)
    @AppStorage("requireAuthorizationForAllCommands")
    var requireAuthorizationForAllCommands: Bool = false

    /// Custom authorization words (comma-separated)
    @AppStorage("customAuthorizationWords")
    var customAuthorizationWords: String = "Authorized, Proceed, Ok, Go, Sure"

    /// Seconds before the authorization prompt auto-cancels
    @AppStorage("authorizationTimeoutSeconds")
    var authorizationTimeoutSeconds: Int = 15

    /// Effective authorization timeout shared by the dialog and the manager so
    /// both clamp identically. Values outside the Stepper range (or invalid 0)
    /// fall back to the 15s default instead of desyncing the two readers.
    var authorizationTimeout: TimeInterval {
        let stored = authorizationTimeoutSeconds
        guard stored > 0 else { return 15 }
        return TimeInterval(min(30, max(5, stored)))
    }

    /// Parsed authorization words; always includes "authorized" as a fallback
    var authorizationWords: [String] {
        var words = customAuthorizationWords
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        if !words.contains("authorized") {
            words.append("authorized")
        }
        return words
    }

    // Debug logging
    @AppStorage("enableCommandLogging") var enableCommandLogging: Bool = false
    // Sound cue settings
    @AppStorage("cueTriggerRecognized") var cueTriggerRecognized: String = CueSound.fishListening.rawValue
    @AppStorage("cueCommandRecognized") var cueCommandRecognized: String = CueSound.happyFish.rawValue
    @AppStorage("cueCommandNotRecognized") var cueCommandNotRecognized: String = CueSound.sadFish.rawValue
    @AppStorage("feedbackSoundVolume") var feedbackSoundVolume: Double = 0.7

    enum CueSound: String, CaseIterable, Identifiable {
        case fishListening
        case happyFish
        case sadFish
        case tap
        case chime
        case bell
        case ding
        case pluck
        case boop
        case pop
        case thud
        case buzz
        case clunk

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .fishListening: return "Fish Listening"
            case .happyFish: return "Happy Fish"
            case .sadFish: return "Sad Fish"
            case .tap: return "Tap"
            case .chime: return "Chime"
            case .bell: return "Bell"
            case .ding: return "Ding"
            case .pluck: return "Pluck"
            case .boop: return "Boop"
            case .pop: return "Pop"
            case .thud: return "Thud"
            case .buzz: return "Buzz"
            case .clunk: return "Clunk"
            }
        }

        /// For bundled sounds, the filename without extension; for system sounds, the system sound name.
        var soundName: String {
            switch self {
            case .fishListening: return "sound_listening"
            case .happyFish: return "sound_command_success"
            case .sadFish: return "sound_command_failure"
            case .tap: return "Morse"
            case .chime: return "Glass"
            case .bell: return "Hero"
            case .ding: return "Ping"
            case .pluck: return "Tink"
            case .boop: return "Pop"
            case .pop: return "Basso"
            case .thud: return "Funk"
            case .buzz: return "Sosumi"
            case .clunk: return "Submarine"
            }
        }

        var isBundled: Bool {
            switch self {
            case .fishListening, .happyFish, .sadFish: return true
            default: return false
            }
        }
    }

    enum CommandFailureBehavior: String, CaseIterable, Identifiable {
        case stopOnError
        case continueOnError

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .stopOnError: return "Stop on error"
            case .continueOnError: return "Continue on error"
            }
        }
    }

    enum AppTheme: String, CaseIterable, Identifiable {
        case systemDefault
        case systemLight
        case systemDark
        
        var id: String { rawValue }
        
        var displayName: String {
            switch self {
            case .systemDefault: return "System Default"
            case .systemLight: return "Light"
            case .systemDark: return "Dark"
            }
        }
    }

    enum CodeBlockTheme: String, CaseIterable {
        case `default`
        case xcode
        case github
        case monokai
    }

    enum SleepInterval: String, CaseIterable, Identifiable {
        case never
        case thirtyMinutes
        case oneHour
        case twoHours
        case fourHours
        case eightHours

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .never: return "Never"
            case .thirtyMinutes: return "30 minutes"
            case .oneHour: return "1 hour"
            case .twoHours: return "2 hours"
            case .fourHours: return "4 hours"
            case .eightHours: return "8 hours"
            }
        }

        var seconds: TimeInterval? {
            switch self {
            case .never: return nil
            case .thirtyMinutes: return 30 * 60
            case .oneHour: return 60 * 60
            case .twoHours: return 2 * 60 * 60
            case .fourHours: return 4 * 60 * 60
            case .eightHours: return 8 * 60 * 60
            }
        }
    }

    enum ConfidenceLevel: String, CaseIterable, Identifiable {
        case casual = "casual"
        case normal = "normal"
        case strict = "strict"

        var id: String { rawValue }

        var threshold: Double {
            switch self {
            case .casual: return 0.70
            case .normal: return 0.75
            case .strict: return 0.80
            }
        }

        var label: String {
            switch self {
            case .casual: return "Casual"
            case .normal: return "Normal"
            case .strict: return "Strict"
            }
        }
    }
}
