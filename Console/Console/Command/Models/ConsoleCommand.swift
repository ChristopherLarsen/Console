import Foundation

// Result type returned by a ConsoleCommand handler
enum ConsoleHandlerResult {
    case success
    case requiresUI      // Handler needed to show panel/UI
    case cancelled       // User cancelled
    case unavailable(reason: String)
}

// A system-level voice command distinct from user-created commands
struct ConsoleCommand: Identifiable {
    let id: String  // e.g., "stop-listening", "note-copy"
    let name: String  // Display name: "Stop Listening"
    let description: String  // e.g., "Stop voice listening"
    let triggerPhrases: [String]  // ["off", "stop", "stop listening"]

    // Execution context
    let availableIn: ModePriority?  // nil = always available
    let requiresConfirmation: Bool
    let contextualCheck: (() -> Bool)?  // Optional context check (e.g., isEditMode for note commands)

    // Execution
    let handler: (@MainActor () async -> ConsoleHandlerResult)
}

extension ConsoleCommand: Hashable {
    static func == (lhs: ConsoleCommand, rhs: ConsoleCommand) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
