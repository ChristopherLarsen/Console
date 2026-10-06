import AppIntents
import SwiftData

struct CreateCommandIntent: AppIntent {
    static var title: LocalizedStringResource = "Create Command"
    static var description = IntentDescription(
        "Save a command. The description is sent as the first message in a new Claude session."
    )

    @Parameter(title: "Description")
    var commandDescription: String

    @Parameter(title: "Trigger Phrases", default: "")
    var triggerPhrases: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let container = AppDependencies.shared.modelContainer else {
            throw IntentError.notReady
        }

        let body = InputSanitizer.commandPrompt(commandDescription)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            throw IntentError.generationFailed("Enter the text Claude should run.")
        }

        let phraseTitle = triggerPhrases
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let firstLine = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? body
        let name = InputSanitizer.commandName(phraseTitle ?? firstLine)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw IntentError.generationFailed("Enter a title.")
        }

        let command = Command(
            name: name,
            claudePrompt: body,
            shortSummary: CommandPromptText.hint(from: body, lineCount: 1)
        )
        let context = ModelContext(container)
        context.insert(command)
        do {
            try context.save()
            NotificationCenter.default.post(name: .commandVocabularyDidChange, object: nil)
        } catch {
            throw IntentError.generationFailed("Failed to save command: \(error.localizedDescription)")
        }

        return .result(value: "Created command \"\(command.name)\".")
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Create command from \(\.$commandDescription)")
    }
}
