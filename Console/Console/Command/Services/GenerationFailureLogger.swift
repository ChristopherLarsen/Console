import Foundation

enum GenerationFailureLogger {
    static func log(
        userDescription: String,
        triggerPhrases: String,
        systemPrompt: String,
        fullPrompt: String,
        provider: AIProvider,
        modelName: String,
        error: Error,
        rawResponse: String?,
        catalogAssisted: Bool,
        retryAttempts: Int
    ) {
        #if DEBUG
        let content = buildReport(
            userDescription: userDescription,
            triggerPhrases: triggerPhrases,
            systemPrompt: systemPrompt,
            fullPrompt: fullPrompt,
            provider: provider,
            modelName: modelName,
            error: error,
            rawResponse: rawResponse,
            catalogAssisted: catalogAssisted,
            retryAttempts: retryAttempts
        )

        guard let logsDir = logsDirectory() else {
            printDebug("GenerationFailureLogger: unable to resolve logs directory")
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let filename = "generation-failure-\(formatter.string(from: Date())).md"
        let fileURL = logsDir.appendingPathComponent(filename)

        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            printDebug("GenerationFailureLogger: saved report to \(fileURL.path)")
        } catch {
            printDebug("GenerationFailureLogger: failed to write report: \(error.localizedDescription)")
        }
        #endif
    }

    // MARK: - Private

    private static func logsDirectory() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let logsDir = appSupport
            .appendingPathComponent("Console", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)

        if !FileManager.default.fileExists(atPath: logsDir.path) {
            try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        }
        return logsDir
    }

    private static func buildReport(
        userDescription: String,
        triggerPhrases: String,
        systemPrompt: String,
        fullPrompt: String,
        provider: AIProvider,
        modelName: String,
        error: Error,
        rawResponse: String?,
        catalogAssisted: Bool,
        retryAttempts: Int
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let dateString = dateFormatter.string(from: Date())

        let errorInfo = classifyError(error)
        let phrases = triggerPhrases.isEmpty ? "None" : triggerPhrases

        let macOSVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let appVersion = BuildConfiguration.appVersion ?? "unknown"
        let buildNumber = BuildConfiguration.buildNumber ?? "unknown"

        var report = """
        # Command Generation Failure Report

        **Date**: \(dateString)
        **Provider**: \(provider.displayName)
        **Model**: \(modelName)
        **Catalog-Assisted**: \(catalogAssisted)
        **Retry Attempts**: \(retryAttempts)

        ## User Input

        **Description**:
        > \(userDescription)

        **Trigger Phrases**:
        > \(phrases)

        ## System Prompt

        ```
        \(systemPrompt)
        ```

        ## Full Prompt Sent

        ```
        \(fullPrompt)
        ```

        ## Error

        **Type**: \(errorInfo.type)
        **Message**: \(errorInfo.message)
        """

        if let underlying = errorInfo.underlying {
            report += "\n**Underlying**: \(underlying)"
        }

        report += """


        ## Raw LLM Response

        ```
        \(rawResponse ?? "Not available")
        ```

        ## Environment

        - **macOS**: \(macOSVersion)
        - **App Version**: \(appVersion) (\(buildNumber))
        """

        return report
    }

    private static func classifyError(_ error: Error) -> (type: String, message: String, underlying: String?) {
        if let llmError = error as? LLMGeneratorError {
            switch llmError {
            case .invalidResponse:
                return ("invalidResponse", "The AI provider returned an invalid response.", nil)
            case .apiError(let msg):
                return ("apiError", msg, nil)
            case .decodingFailed(let detail):
                return ("decodingFailed", detail, nil)
            case .missingAPIKey:
                return ("missingAPIKey", "No API key configured for the selected provider.", nil)
            case .networkError(let underlying):
                let nsError = underlying as NSError
                return ("networkError", underlying.localizedDescription, "domain=\(nsError.domain) code=\(nsError.code)")
            case .notAvailable(let msg, _):
                return ("notAvailable", msg, nil)
            case .ambiguousRequest(let msg, _):
                return ("ambiguousRequest", msg, nil)
            case .tooComplex(let msg, _):
                return ("tooComplex", msg, nil)
            case .safetyExceeded(let msg, _):
                return ("safetyExceeded", msg, nil)
            case .unknownError(let msg):
                return ("unknownError", msg, nil)
            }
        }

        let nsError = error as NSError
        return ("unknown", error.localizedDescription, "domain=\(nsError.domain) code=\(nsError.code)")
    }
}
