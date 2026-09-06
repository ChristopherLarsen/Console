import Foundation
import FoundationModels

@available(macOS 26.0, *)
struct OpenApplicationTool: Tool {
    let name = "openApplication"
    let description = "Open or switch to a macOS application by name. Examples: Safari, Cursor, Terminal, Finder, Mail, Messages, Xcode."

    @Generable
    struct Arguments {
        @Guide(description: "The name of the macOS application to open, e.g. Safari, Cursor, Terminal")
        var applicationName: String
    }

    func call(arguments: Arguments) async throws -> String {
        try await AppleScriptRunner.openApplication(name: arguments.applicationName)
    }
}
