import Foundation
import FoundationModels

@available(macOS 26.0, *)
struct SystemControlTool: Tool {
    let name = "systemControl"
    let description = "Control macOS system settings. Supported actions: setVolume (with a level 0-100), toggleDarkMode."

    @Generable
    struct Arguments {
        @Guide(description: "The control action. Must be one of: setVolume, toggleDarkMode")
        var controlType: String

        @Guide(description: "Numeric value when applicable. For setVolume: a number 0-100. Not needed for toggleDarkMode.")
        var value: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        switch arguments.controlType.lowercased() {
        case "setvolume":
            let level = arguments.value ?? 50
            return try await AppleScriptRunner.setVolume(level: level)
        case "toggledarkmode":
            return try await AppleScriptRunner.toggleDarkMode()
        default:
            return "Unknown system control action: \(arguments.controlType)"
        }
    }
}
