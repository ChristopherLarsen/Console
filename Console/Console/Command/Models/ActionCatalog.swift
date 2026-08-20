import Foundation

struct ActionCatalog: Codable {
    let version: String
    let lastUpdated: Date
    let macOSVersions: [String]
    let apps: [AppCatalogEntry]

    func formattedForPrompt() -> String {
        var output = "CATALOG VERSION: \(version)\n\n"

        for app in apps {
            output += "APP: \(app.name) (\(app.bundleID))\n"

            if !app.appIntents.isEmpty {
                output += "  App Intents:\n"
                for intent in app.appIntents {
                    output += "    - \(intent.intentName): \(intent.intentDescription)\n"
                    for param in intent.parameters {
                        let req = param.isRequired ? " [required]" : ""
                        output += "      • \(param.name) (\(param.type))\(req)\n"
                    }
                }
            }

            if !app.applescriptActions.isEmpty {
                output += "  AppleScript:\n"
                for action in app.applescriptActions {
                    output += "    - \(action.functionName): \(action.actionDescription)\n"
                }
            }

            if !app.shellCommands.isEmpty {
                output += "  Shell:\n"
                for cmd in app.shellCommands {
                    output += "    - \(cmd.name): \(cmd.commandDescription)\n"
                }
            }

            output += "\n"
        }

        return output
    }
}

struct AppCatalogEntry: Codable {
    let name: String
    let bundleID: String
    let minMacOSVersion: String
    let appIntents: [AppIntentEntry]
    let applescriptActions: [AppleScriptCatalogEntry]
    let shellCommands: [ShellCommandEntry]
    let commonPatterns: [CommandPattern]
    let knownIssues: [String]
    let timingHeuristics: TimingHeuristics

    struct TimingHeuristics: Codable {
        let launchDelay: Int
        let actionDelay: Int
    }
}

struct AppIntentEntry: Codable {
    let intentName: String
    let intentDescription: String
    let parameters: [IntentParameter]
    let exampleUsage: String
    let reliabilityScore: Double
    let avgExecutionTimeMS: Int

    struct IntentParameter: Codable {
        let name: String
        let type: String
        let isRequired: Bool
        let defaultValue: String?
        let parameterDescription: String?
    }
}

struct AppleScriptCatalogEntry: Codable {
    let functionName: String
    let scriptTemplate: String
    let actionDescription: String
    let parameters: [String]
    let reliabilityScore: Double
    let avgExecutionTimeMS: Int
}

struct ShellCommandEntry: Codable {
    let name: String
    let command: String
    let argsTemplate: [String]
    let safetyCheck: String?
    let commandDescription: String
}

struct CommandPattern: Codable {
    let userIntent: String
    let exampleActions: [String]
}

// MARK: - Catalog Manager

class ActionCatalogManager {
    static let shared = ActionCatalogManager()

    private var catalog: ActionCatalog?

    private init() {
        loadCatalog()
    }

    func getCatalog() -> ActionCatalog? {
        catalog
    }

    func reloadCatalog() {
        loadCatalog()
    }

    func findAppEntry(bundleID: String) -> AppCatalogEntry? {
        catalog?.apps.first(where: { $0.bundleID == bundleID })
    }

    func findAppEntry(name: String) -> AppCatalogEntry? {
        catalog?.apps.first(where: { $0.name.lowercased() == name.lowercased() })
    }

    private func loadCatalog() {
        guard let url = Bundle.main.url(forResource: "ActionCatalog", withExtension: "json") else {
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            catalog = try decoder.decode(ActionCatalog.self, from: data)
        } catch {
            printDebug("Error loading action catalog: \(error)")
        }
    }
}
