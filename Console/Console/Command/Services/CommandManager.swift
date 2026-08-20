import Foundation


@MainActor @Observable
final class CommandManager {
    static let shared = CommandManager()
    
    private init() {}
    
    func handleCommand(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return }
        printDebug("CommandManager: received command -- \(trimmed)")
        // If the trimmed string is "open cursor", 
        if trimmed == "open cursor" {
            // Create an AppleScript to open Cursor
            let script = """
            tell application "Cursor"
                activate
            end tell
            """
            let appleScript = NSAppleScript(source: script)
            appleScript?.executeAndReturnError(nil)
            return
        }
        if trimmed == "build" {
            // Create an AppleScript to open Terminal
            let script = """
            tell application "Xcode"
                activate
                run build
            end tell
            """
            let appleScript = NSAppleScript(source: script)
            appleScript?.executeAndReturnError(nil)
            return
        }
    }
    
    func userStoppedSpeaking() {
        printDebug("CommandManager: user stopped speaking")
    }
}
