import Foundation

protocol IOSResultParsing: Sendable {
    func parseBundle(at url: URL, jobKind: IOSBuildJobKind) async -> IOSResultSummary
}

/// Structured `xcrun xcresulttool get …` argv. Local inspection only: no
/// `export`, no log dump, no upload flags.
nonisolated enum IOSXcresulttoolCommand {
    static let defaultXcrunPath = "/usr/bin/xcrun"
    static let toolName = "xcresulttool"

    enum Query: String, Equatable, Sendable {
        case contentAvailability = "content-availability"
        case buildResults = "build-results"
        case testSummary = "test-results-summary"
        case tests = "test-results-tests"
    }

    static func makeLaunchSpec(
        query: Query,
        bundleURL: URL,
        xcrunPath: String = defaultXcrunPath
    ) -> ProcessLaunchSpec {
        var arguments = [toolName, "get"]
        switch query {
        case .contentAvailability:
            arguments.append("content-availability")
        case .buildResults:
            arguments.append("build-results")
        case .testSummary:
            arguments.append(contentsOf: ["test-results", "summary"])
        case .tests:
            arguments.append(contentsOf: ["test-results", "tests"])
        }
        arguments.append(contentsOf: ["--path", bundleURL.path, "--compact"])
        return ProcessLaunchSpec(
            executablePath: xcrunPath,
            arguments: arguments,
            workingDirectory: nil
        )
    }
}

/// Inspects a Console-owned `.xcresult` with installed `xcresulttool`
/// subcommands and returns a bounded summary of build issues and test
/// failures. Exit status of the build job remains authoritative; this parser
/// never infers success from log text and never uploads the bundle.
struct IOSResultParser: IOSResultParsing, Sendable {
    nonisolated static let defaultToolTimeout: TimeInterval = 15
    nonisolated static let maxTestNodesWalked = 400

    private let processRunner: any ProcessRunning
    private let xcrunPath: String
    private let toolTimeout: TimeInterval
    private let bundlePresenceHandler: @Sendable (String) -> (exists: Bool, isDirectory: Bool)

    init(
        processRunner: any ProcessRunning,
        xcrunPath: String = IOSXcresulttoolCommand.defaultXcrunPath,
        toolTimeout: TimeInterval = defaultToolTimeout,
        bundlePresence: (@Sendable (String) -> (exists: Bool, isDirectory: Bool))? = nil
    ) {
        self.processRunner = processRunner
        self.xcrunPath = xcrunPath
        self.toolTimeout = toolTimeout
        self.bundlePresenceHandler = bundlePresence ?? { path in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            return (exists, isDirectory.boolValue)
        }
    }

    func parseBundle(at url: URL, jobKind: IOSBuildJobKind) async -> IOSResultSummary {
        switch bundlePresence(at: url) {
        case .missing:
            return .unparsed(
                .missingBundle,
                message: "The result bundle was not found at \(url.path)."
            )
        case .file:
            return .unparsed(
                .corruptBundle,
                message: "The result bundle path exists but is not an .xcresult bundle."
            )
        case .directory:
            break
        }

        let availability = await runQuery(.contentAvailability, bundleURL: url)
        var hasTestResults: Bool?
        switch availability {
        case .failure(let summary):
            if summary.parseStatus == .missingBundle
                || summary.parseStatus == .incompleteBundle
                || summary.parseStatus == .corruptBundle {
                return summary
            }
        case .success(let json):
            hasTestResults = Self.boolValue(json["hasTestResults"])
        }

        let buildAttempt = await runQuery(.buildResults, bundleURL: url)
        var buildIssues: [IOSResultIssue] = []
        var buildOutcome = IOSResultOutcome.unknown
        var buildErrorCount = 0
        var recognizedBuild = false
        var firstDiagnostic: String?

        switch buildAttempt {
        case .failure(let summary):
            firstDiagnostic = summary.diagnosticMessage
            if summary.parseStatus == .missingBundle
                || summary.parseStatus == .incompleteBundle
                || summary.parseStatus == .corruptBundle {
                return summary
            }
        case .success(let json):
            if let parsed = Self.buildResults(from: json) {
                recognizedBuild = true
                buildIssues = parsed.issues
                buildOutcome = parsed.outcome
                buildErrorCount = parsed.errorCount
            } else {
                firstDiagnostic = "xcresulttool build-results JSON did not match the expected schema."
            }
        }

        let shouldReadTests: Bool
        switch jobKind {
        case .runSelectedTests:
            shouldReadTests = hasTestResults ?? true
        case .build:
            shouldReadTests = hasTestResults ?? false
        }

        var testIssues: [IOSResultIssue] = []
        var testOutcome = IOSResultOutcome.unknown
        var failedTestCount = 0
        var recognizedTests = false

        if shouldReadTests {
            let summaryAttempt = await runQuery(.testSummary, bundleURL: url)
            switch summaryAttempt {
            case .failure(let summary):
                if firstDiagnostic == nil {
                    firstDiagnostic = summary.diagnosticMessage
                }
            case .success(let json):
                if let parsed = Self.testSummary(from: json) {
                    recognizedTests = true
                    testIssues = parsed.issues
                    testOutcome = parsed.outcome
                    failedTestCount = parsed.failedTestCount
                } else if firstDiagnostic == nil {
                    firstDiagnostic = "xcresulttool test-results summary JSON did not match the expected schema."
                }
            }

            if recognizedTests, failedTestCount > 0 || testIssues.contains(where: { $0.kind == .testFailure }) {
                let testsAttempt = await runQuery(.tests, bundleURL: url)
                if case .success(let json) = testsAttempt {
                    let locations = Self.sourceLocationsByTestIdentifier(from: json)
                    testIssues = Self.merging(testIssues, locations: locations)
                }
            }
        }

        if !recognizedBuild && !recognizedTests {
            if let firstDiagnostic {
                return .unparsed(.schemaMismatch, message: firstDiagnostic)
            }
            return .unparsed(
                .schemaMismatch,
                message: "xcresulttool output did not match a known result schema."
            )
        }

        var issues = buildIssues + testIssues
        if issues.count > IOSResultSummary.maxIssues {
            issues = Array(issues.prefix(IOSResultSummary.maxIssues))
        }

        let recordsFailed = buildOutcome == .failed
            || testOutcome == .failed
            || buildErrorCount > 0
            || failedTestCount > 0
        let outcome: IOSResultOutcome
        if recordsFailed {
            outcome = .failed
        } else if recognizedBuild || recognizedTests {
            outcome = .succeeded
        } else {
            outcome = .unknown
        }

        return .parsed(
            outcome: outcome,
            issues: issues,
            errorCount: buildErrorCount,
            failedTestCount: failedTestCount,
            diagnosticMessage: firstDiagnostic
        )
    }

    // MARK: - Bundle presence

    private enum BundlePresence {
        case missing
        case file
        case directory
    }

    private func bundlePresence(at url: URL) -> BundlePresence {
        let presence = bundlePresenceHandler(url.path)
        if !presence.exists { return .missing }
        return presence.isDirectory ? .directory : .file
    }

    // MARK: - Tool invocation

    private enum QueryResult {
        case success([String: Any])
        case failure(IOSResultSummary)
    }

    private func runQuery(
        _ query: IOSXcresulttoolCommand.Query,
        bundleURL: URL
    ) async -> QueryResult {
        let spec = IOSXcresulttoolCommand.makeLaunchSpec(
            query: query,
            bundleURL: bundleURL,
            xcrunPath: xcrunPath
        )
        let result: ProcessResult
        do {
            result = try await processRunner.run(
                executablePath: spec.executablePath,
                arguments: spec.arguments,
                workingDirectory: spec.workingDirectory,
                deadline: Date().addingTimeInterval(toolTimeout)
            )
        } catch let error as ProcessRunError {
            return .failure(summary(for: error))
        } catch is CancellationError {
            return .failure(.unparsed(.toolFailed, message: ProcessRunError.cancelled.localizedDescription))
        } catch {
            return .failure(.unparsed(.toolFailed, message: error.localizedDescription))
        }

        if result.standardOutputTruncated || result.standardErrorTruncated {
            return .failure(.unparsed(
                .incompleteBundle,
                message: "xcresulttool output was truncated before it could be parsed."
            ))
        }

        let combined = (result.standardOutput + "\n" + result.standardError).lowercased()
        if result.exitCode != 0 {
            return .failure(summary(forToolFailure: combined, exitCode: result.exitCode))
        }

        guard let json = Self.jsonObject(in: result.standardOutput) else {
            return .failure(.unparsed(
                .schemaMismatch,
                message: "xcresulttool did not return JSON for \(query.rawValue)."
            ))
        }
        return .success(json)
    }

    private func summary(for error: ProcessRunError) -> IOSResultSummary {
        switch error {
        case .timedOut:
            return .unparsed(.incompleteBundle, message: "xcresulttool timed out.")
        case .cancelled:
            return .unparsed(.toolFailed, message: error.localizedDescription)
        case .executableMissing(let path):
            return .unparsed(.toolFailed, message: "xcresulttool was not found at \(path).")
        case .launchFailed(let message):
            return .unparsed(.toolFailed, message: "Could not start xcresulttool: \(message)")
        }
    }

    private func summary(forToolFailure combined: String, exitCode: Int32) -> IOSResultSummary {
        if combined.contains("does not exist")
            || combined.contains("no such file")
            || combined.contains("could not find") {
            return .unparsed(.missingBundle, message: "xcresulttool could not find the result bundle.")
        }
        if combined.contains("incomplete") {
            return .unparsed(.incompleteBundle, message: "The result bundle is incomplete.")
        }
        if combined.contains("unknown version") || combined.contains("schema") {
            return .unparsed(.schemaMismatch, message: "xcresulttool rejected the result schema.")
        }
        if combined.contains("corrupt")
            || combined.contains("unreadable")
            || combined.contains("failed to load")
            || combined.contains("unable to read") {
            return .unparsed(.corruptBundle, message: "The result bundle could not be read.")
        }
        return .unparsed(
            .toolFailed,
            message: "xcresulttool failed (exit code \(exitCode))."
        )
    }

    // MARK: - JSON

    static func jsonObject(in output: String) -> [String: Any]? {
        guard let data = jsonValueData(in: output) else { return nil }
        guard let value = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return value as? [String: Any]
    }

    static func jsonValueData(in output: String) -> Data? {
        if let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}") {
            return String(output[start...end]).data(using: .utf8)
        }
        return nil
    }

    static func buildResults(from json: [String: Any]) -> (
        issues: [IOSResultIssue],
        outcome: IOSResultOutcome,
        errorCount: Int
    )? {
        let errors = objectArray(json["errors"])
        let hasStatus = json["status"] != nil
        let hasErrorCount = json["errorCount"] != nil
        let hasActionTitle = json["actionTitle"] != nil
        guard json["errors"] != nil || hasStatus || hasErrorCount || hasActionTitle else {
            return nil
        }

        let reportedCount = intValue(json["errorCount"]) ?? errors.count
        let issues: [IOSResultIssue] = errors.prefix(IOSResultSummary.maxIssues).map { item in
            let rawURL = stringValue(item["sourceURL"]) ?? stringValue(item["url"])
            let location = sourceLocation(from: rawURL)
            return IOSResultIssue(
                kind: .buildError,
                message: stringValue(item["message"]) ?? "Build failed.",
                fileURL: location.fileURL,
                line: location.line,
                testIdentifier: nil
            )
        }
        let outcome = outcome(fromStatus: stringValue(json["status"]), failingCount: reportedCount)
        return (issues, outcome, reportedCount)
    }

    static func testSummary(from json: [String: Any]) -> (
        issues: [IOSResultIssue],
        outcome: IOSResultOutcome,
        failedTestCount: Int
    )? {
        let failures = objectArray(json["testFailures"])
        let hasResult = json["result"] != nil
        let hasFailedCount = json["failedTests"] != nil
        guard json["testFailures"] != nil || hasResult || hasFailedCount || json["totalTestCount"] != nil else {
            return nil
        }

        let failedCount = intValue(json["failedTests"]) ?? failures.count
        let issues: [IOSResultIssue] = failures.prefix(IOSResultSummary.maxIssues).map { item in
            let identifier = stringValue(item["testIdentifierString"])
                ?? Self.normalizedTestIdentifier(stringValue(item["testIdentifierURL"]))
            return IOSResultIssue(
                kind: .testFailure,
                message: stringValue(item["failureText"])
                    ?? stringValue(item["testName"])
                    ?? "Test failed.",
                fileURL: nil,
                line: nil,
                testIdentifier: identifier
            )
        }
        let outcome = outcome(fromStatus: stringValue(json["result"]), failingCount: failedCount)
        return (issues, outcome, failedCount)
    }

    /// `test://` identifier URLs and slash-style identifiers must map to the
    /// same key so source-location merging (and rerun) treat them alike.
    static func normalizedTestIdentifier(_ raw: String?) -> String? {
        guard let raw,
              let components = URLComponents(string: raw),
              components.scheme == "test" else { return raw }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty ? nil : path
    }

    static func sourceLocationsByTestIdentifier(from json: [String: Any]) -> [String: (fileURL: URL?, line: Int?)] {
        guard let nodes = json["testNodes"] as? [Any] else { return [:] }
        var found: [String: (fileURL: URL?, line: Int?)] = [:]
        var visited = 0
        walkTestNodes(nodes, identifier: nil, into: &found, visited: &visited)
        return found
    }

    static func merging(
        _ issues: [IOSResultIssue],
        locations: [String: (fileURL: URL?, line: Int?)]
    ) -> [IOSResultIssue] {
        issues.map { issue in
            guard let identifier = issue.testIdentifier, let location = locations[identifier] else {
                return issue
            }
            var copy = issue
            if copy.fileURL == nil { copy.fileURL = location.fileURL }
            if copy.line == nil { copy.line = location.line }
            return copy
        }
    }

    private static func walkTestNodes(
        _ nodes: [Any],
        identifier: String?,
        into found: inout [String: (fileURL: URL?, line: Int?)],
        visited: inout Int
    ) {
        for node in nodes {
            if visited >= maxTestNodesWalked { return }
            visited += 1
            guard let object = node as? [String: Any] else { continue }
            let nodeType = stringValue(object["nodeType"]) ?? ""
            let currentIdentifier = Self.normalizedTestIdentifier(stringValue(object["nodeIdentifier"]))
                ?? Self.normalizedTestIdentifier(stringValue(object["nodeIdentifierURL"]))
                ?? identifier

            if nodeType == "Source Code Reference", let currentIdentifier {
                let raw = stringValue(object["details"]) ?? stringValue(object["name"])
                let location = sourceLocation(from: raw)
                if location.fileURL != nil || location.line != nil {
                    found[currentIdentifier] = location
                }
            }

            if let children = object["children"] as? [Any] {
                walkTestNodes(children, identifier: currentIdentifier, into: &found, visited: &visited)
            }
        }
    }

    static func sourceLocation(from raw: String?) -> (fileURL: URL?, line: Int?) {
        guard let raw else { return (nil, nil) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, nil) }

        if let components = URLComponents(string: trimmed), components.scheme == "file" {
            let line = lineNumber(fromFragment: components.fragment)
            var cleaned = components
            cleaned.fragment = nil
            return (cleaned.url, line)
        }

        if trimmed.hasPrefix("/"), !trimmed.contains("://") {
            let (path, line) = pathAndLine(trimmed)
            return (URL(fileURLWithPath: path), line)
        }

        if let colon = trimmed.firstIndex(of: ":") {
            let pathPart = String(trimmed[..<colon])
            if pathPart.contains("/") || pathPart.contains("\\") || pathPart.contains(".") {
                let (path, line) = pathAndLine(trimmed)
                let url: URL? = path.hasPrefix("/")
                    ? URL(fileURLWithPath: path)
                    : nil
                if url != nil || line != nil {
                    return (url, line)
                }
            }
        }

        return (nil, nil)
    }

    private static func pathAndLine(_ raw: String) -> (String, Int?) {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if parts.count >= 2, let line = Int(parts[1]) {
            return (parts[0], line)
        }
        return (raw, nil)
    }

    static func lineNumber(fromFragment fragment: String?) -> Int? {
        guard let fragment, !fragment.isEmpty else { return nil }
        let pairs = fragment.split(separator: "&")
        var starting: Int?
        var ending: Int?
        for pair in pairs {
            let pieces = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { continue }
            let value = Int(pieces[1])
            switch pieces[0] {
            case "StartingLineNumber", "startingLineNumber", "line":
                starting = value
            case "EndingLineNumber", "endingLineNumber":
                ending = value
            default:
                break
            }
        }
        return starting ?? ending
    }

    static func outcome(fromStatus status: String?, failingCount: Int) -> IOSResultOutcome {
        if failingCount > 0 { return .failed }
        guard let status else { return .unknown }
        switch status.lowercased() {
        case "failed", "failure", "error":
            return .failed
        case "passed", "succeeded", "success":
            return .succeeded
        default:
            return .unknown
        }
    }

    static func objectArray(_ value: Any?) -> [[String: Any]] {
        if let array = value as? [[String: Any]] { return array }
        if let object = value as? [String: Any] { return [object] }
        if let array = value as? [Any] {
            return array.compactMap { $0 as? [String: Any] }
        }
        return []
    }

    static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    static func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }
}
