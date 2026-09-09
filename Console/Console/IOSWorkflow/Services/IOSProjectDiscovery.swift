import Foundation

nonisolated enum IOSProjectDiscoveryError: LocalizedError, Equatable {
    case executableMissing(String)
    case timedOut
    case cancelled
    case commandFailed(description: String, exitCode: Int32, stderr: String)
    case invalidJSON(String)
    case outputTruncated

    var errorDescription: String? {
        switch self {
        case .executableMissing(let path):
            return "xcodebuild was not found at \(path)."
        case .timedOut:
            return "xcodebuild timed out while reading the project."
        case .cancelled:
            return "Project discovery was cancelled."
        case .commandFailed(let description, let exitCode, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "\(description) failed (exit code \(exitCode))."
                : "\(description) failed (exit code \(exitCode)): \(detail)"
        case .invalidJSON:
            return "xcodebuild returned a project listing that could not be parsed."
        case .outputTruncated:
            return "xcodebuild output was truncated before it could be parsed."
        }
    }
}

/// Validates the project the user picked in the open panel. Accepts the
/// `.xcodeproj` / `.xcworkspace` bundle itself, or a folder that contains
/// exactly one such bundle. Never walks deeper than direct children.
nonisolated enum IOSProjectManualSelection {
    enum Outcome: Equatable {
        case selected(IOSProjectCandidate)
        case invalid(String)

        var message: String? {
            if case .invalid(let text) = self { return text }
            return nil
        }
    }

    nonisolated static let notAProjectMessage =
        "Choose an Xcode project (.xcodeproj) or workspace (.xcworkspace)."

    static func resolve(
        url: URL,
        fileManager: FileManager = .default
    ) -> Outcome {
        let path = url.standardizedFileURL.path
        if let candidate = IOSProjectCandidate(path: path) {
            guard fileManager.fileExists(atPath: candidate.path) else {
                return .invalid(notAProjectMessage)
            }
            return .selected(candidate)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .invalid(notAProjectMessage)
        }
        let children: [String]
        do {
            children = try fileManager.contentsOfDirectory(atPath: path)
        } catch {
            return .invalid(notAProjectMessage)
        }
        let candidates = children
            .compactMap { IOSProjectCandidate(path: URL(fileURLWithPath: path).appendingPathComponent($0).path) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        switch candidates.count {
        case 1:
            return .selected(candidates[0])
        case 0:
            return .invalid(notAProjectMessage)
        default:
            return .invalid("That folder contains several Xcode projects. Choose one directly.")
        }
    }
}

/// Parses `xcodebuild -list -json`, `-showTestPlans`, and `-showdestinations`
/// output. Fixtures cover JSON and the brace-line destination text format.
nonisolated enum IOSXcodebuildOutputParser {
    static func listing(fromListJSON output: String) throws -> IOSProjectListing {
        guard let data = jsonValueData(in: output) else {
            throw IOSProjectDiscoveryError.invalidJSON("missing JSON object")
        }
        let decoded: ListEnvelope
        do {
            decoded = try JSONDecoder().decode(ListEnvelope.self, from: data)
        } catch {
            throw IOSProjectDiscoveryError.invalidJSON(error.localizedDescription)
        }
        if let project = decoded.project {
            return IOSProjectListing(
                name: project.name ?? "",
                schemes: sanitized(project.schemes),
                configurations: sanitized(project.configurations),
                targets: sanitized(project.targets),
                testPlans: nil
            )
        }
        if let workspace = decoded.workspace {
            return IOSProjectListing(
                name: workspace.name ?? "",
                schemes: sanitized(workspace.schemes),
                configurations: sanitized(workspace.configurations),
                targets: sanitized(workspace.targets),
                testPlans: nil
            )
        }
        throw IOSProjectDiscoveryError.invalidJSON("missing project or workspace")
    }

    static func testPlans(from output: String) -> [String] {
        if let data = jsonValueData(in: output),
           let value = try? JSONSerialization.jsonObject(with: data) {
            return extractNames(from: value)
        }
        return testPlansFromText(output)
    }

    static func destinations(from output: String) -> [IOSSimulatorDestination] {
        if let data = jsonValueData(in: output),
           let value = try? JSONSerialization.jsonObject(with: data) {
            let parsed = destinations(fromJSON: value)
            if !parsed.isEmpty { return parsed }
        }
        return destinationsFromText(output)
    }

    static func jsonValueData(in output: String) -> Data? {
        if let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}") {
            return String(output[start...end]).data(using: .utf8)
        }
        if let start = output.firstIndex(of: "["), let end = output.lastIndex(of: "]") {
            return String(output[start...end]).data(using: .utf8)
        }
        return nil
    }

    static func testPlansFromText(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let lower = trimmed.lowercased()
            if lower.hasPrefix("xcodebuild:") { return nil }
            if lower.contains("test plan") && (lower.contains("scheme") || lower.contains("associated")) {
                return nil
            }
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("-") { return nil }
            return trimmed
        }
    }

    static func destinationsFromText(_ output: String) -> [IOSSimulatorDestination] {
        output.split(whereSeparator: \.isNewline).compactMap { destination(fromBraceLine: String($0)) }
    }

    static func destination(fromBraceLine line: String) -> IOSSimulatorDestination? {
        guard let open = line.firstIndex(of: "{"),
              let close = line.lastIndex(of: "}") else { return nil }
        let body = String(line[line.index(after: open)..<close])
        let platform = value(forKey: "platform", in: body)
        guard isIOSSimulator(platform: platform) else { return nil }
        guard let udid = value(forKey: "id", in: body).flatMap({ sanitizedUDID($0) }) else { return nil }
        let name = value(forKey: "name", in: body) ?? udid
        return IOSSimulatorDestination(
            udid: udid,
            name: name,
            osVersion: value(forKey: "OS", in: body),
            platform: platform ?? "iOS Simulator"
        )
    }

    private static func destinations(fromJSON value: Any) -> [IOSSimulatorDestination] {
        let items: [Any]
        if let array = value as? [Any] {
            items = array
        } else if let dict = value as? [String: Any] {
            items = (dict["destinations"] as? [Any]) ?? []
        } else {
            items = []
        }
        return items.compactMap { item in
            guard let dict = item as? [String: Any] else { return nil }
            let platform = dict["platform"] as? String
            guard isIOSSimulator(platform: platform) else { return nil }
            let udid = (dict["id"] as? String) ?? (dict["udid"] as? String)
            guard let udid, let clean = sanitizedUDID(udid) else { return nil }
            let name = (dict["name"] as? String).flatMap(IOSProjectProfile.nilIfEmpty) ?? clean
            let os = (dict["OS"] as? String) ?? (dict["os"] as? String)
            return IOSSimulatorDestination(
                udid: clean,
                name: name,
                osVersion: IOSProjectProfile.nilIfEmpty(os),
                platform: platform ?? "iOS Simulator"
            )
        }
    }

    private static func extractNames(from value: Any) -> [String] {
        if let strings = value as? [String] {
            return sanitized(strings)
        }
        if let array = value as? [Any] {
            return sanitized(array.compactMap { item in
                if let string = item as? String { return string }
                if let dict = item as? [String: Any] { return dict["name"] as? String }
                return nil
            })
        }
        if let dict = value as? [String: Any], let plans = dict["testPlans"] {
            return extractNames(from: plans)
        }
        return []
    }

    private static func value(forKey key: String, in body: String) -> String? {
        let marker = "\(key):"
        guard let range = body.range(of: marker) else { return nil }
        let after = body[range.upperBound...]
        let nextKeys = ["platform:", "arch:", "id:", "OS:", "name:", "variant:"]
        var end = after.endIndex
        for next in nextKeys where !next.hasPrefix("\(key):") {
            let commaNext = ", \(next)"
            if let found = after.range(of: commaNext) ?? after.range(of: ",\(next)"),
               found.lowerBound < end {
                end = found.lowerBound
            }
        }
        let raw = after[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        return IOSProjectProfile.nilIfEmpty(raw)
    }

    static func isIOSSimulator(platform: String?) -> Bool {
        guard let platform else { return false }
        let lowered = platform.lowercased()
        return lowered.contains("ios") && lowered.contains("simulator")
    }

    static func sanitizedUDID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        if lowered.contains("placeholder") || lowered.contains("dvtdevice") {
            return nil
        }
        return trimmed
    }

    private static func sanitized(_ values: [String]?) -> [String] {
        (values ?? []).compactMap(IOSProjectProfile.nilIfEmpty)
    }

    private struct ListEnvelope: Decodable {
        var project: ListBody?
        var workspace: ListBody?

        struct ListBody: Decodable {
            var name: String?
            var schemes: [String]?
            var configurations: [String]?
            var targets: [String]?
        }
    }
}

/// Reads schemes, test plans, and Simulator destinations for the
/// user-selected project through structured `xcodebuild` argv. Never builds,
/// never parses a shell string, never searches the filesystem for projects.
nonisolated struct IOSProjectDiscovery {
    nonisolated static let xcodebuildPath = "/usr/bin/xcodebuild"
    nonisolated static let listTimeout: TimeInterval = 20
    nonisolated static let testPlanTimeout: TimeInterval = 15
    nonisolated static let destinationTimeout: TimeInterval = 20
    nonisolated static let destinationLookupSeconds = 8

    private let processRunner: any ProcessRunning
    private let xcodebuildPath: String

    nonisolated init(
        processRunner: any ProcessRunning = SystemProcessRunner(maxOutputBytesPerStream: 262_144),
        xcodebuildPath: String = IOSProjectDiscovery.xcodebuildPath
    ) {
        self.processRunner = processRunner
        self.xcodebuildPath = xcodebuildPath
    }

    func list(_ candidate: IOSProjectCandidate) async throws -> IOSProjectListing {
        let arguments = ["-list", "-json"] + specifierArguments(for: candidate)
        let result = try await runXcodebuild(
            arguments: arguments,
            timeout: Self.listTimeout,
            description: "xcodebuild -list"
        )
        return try IOSXcodebuildOutputParser.listing(fromListJSON: result.standardOutput)
    }

    func listTestPlans(candidate: IOSProjectCandidate, scheme: String) async -> IOSLookup<[String]> {
        let base = ["-showTestPlans"] + specifierArguments(for: candidate) + ["-scheme", scheme]
        do {
            let output = try await runPreferringJSON(
                baseArguments: base,
                timeout: Self.testPlanTimeout,
                description: "xcodebuild -showTestPlans"
            )
            return .succeeded(IOSXcodebuildOutputParser.testPlans(from: output))
        } catch is CancellationError {
            return .failed
        } catch let error as IOSProjectDiscoveryError where error == .cancelled {
            return .failed
        } catch {
            return .failed
        }
    }

    func listDestinations(candidate: IOSProjectCandidate, scheme: String) async -> IOSLookup<[IOSSimulatorDestination]> {
        let base = [
            "-showdestinations",
            "-destination-timeout",
            "\(Self.destinationLookupSeconds)"
        ] + specifierArguments(for: candidate) + ["-scheme", scheme]
        do {
            let output = try await runPreferringJSON(
                baseArguments: base,
                timeout: Self.destinationTimeout,
                description: "xcodebuild -showdestinations"
            )
            return .succeeded(IOSXcodebuildOutputParser.destinations(from: output))
        } catch is CancellationError {
            return .failed
        } catch let error as IOSProjectDiscoveryError where error == .cancelled {
            return .failed
        } catch {
            return .failed
        }
    }

    func specifierArguments(for candidate: IOSProjectCandidate) -> [String] {
        switch candidate.kind {
        case .workspace:
            return ["-workspace", candidate.path]
        case .project:
            return ["-project", candidate.path]
        }
    }

    /// Bounded xcodebuild reads for the user-selected project. No filesystem
    /// search: the project path comes from the profile the user picked in
    /// Settings. A failed xcodebuild call returns the saved profile unchanged
    /// aside from unambiguous empty field auto-fill that does not require
    /// xcodebuild.
    func refresh(
        saved: IOSProjectProfile,
        progress: ((IOSDiscoveryPhase) -> Void)? = nil
    ) async -> IOSDiscoveryRefreshResult {
        var listingLookup: IOSLookup<IOSProjectListing> = .skipped
        var destinationLookup: IOSLookup<[IOSSimulatorDestination]> = .skipped
        var errorMessage: String?
        var listing: IOSProjectListing?

        if Task.isCancelled {
            return cancelledResult(saved: saved)
        }

        if let candidate = candidateToQuery(path: saved.projectPath) {
            progress?(.listingSchemes)
            do {
                var listed = try await list(candidate)
                listingLookup = .succeeded(listed)
                listing = listed

                let schemeForLookup = schemeForFollowup(saved: saved, listing: listed)
                if let schemeForLookup {
                    progress?(.listingTestPlans)
                    let plans = await listTestPlans(candidate: candidate, scheme: schemeForLookup)
                    if case .succeeded(let names) = plans {
                        listed.testPlans = names
                    }
                    listing = listed
                    listingLookup = .succeeded(listed)

                    progress?(.listingDestinations)
                    destinationLookup = await listDestinations(candidate: candidate, scheme: schemeForLookup)
                }
            } catch is CancellationError {
                return cancelledResult(saved: saved)
            } catch let error as IOSProjectDiscoveryError where error == .cancelled {
                return cancelledResult(saved: saved)
            } catch {
                listingLookup = .failed
                destinationLookup = .failed
                errorMessage = error.localizedDescription
                listing = nil
            }
        }

        if Task.isCancelled {
            return cancelledResult(saved: saved)
        }

        let repair = IOSProfileRepair.resolve(
            saved: saved,
            listing: listingLookup,
            destinations: destinationLookup
        )
        let destinations: [IOSSimulatorDestination]
        if case .succeeded(let devices) = destinationLookup {
            destinations = devices
        } else {
            destinations = []
        }
        return IOSDiscoveryRefreshResult(
            listing: listing,
            destinations: destinations,
            repair: repair,
            errorMessage: errorMessage,
            listingLookup: listingLookup,
            destinationLookup: destinationLookup
        )
    }

    private func cancelledResult(
        saved: IOSProjectProfile
    ) -> IOSDiscoveryRefreshResult {
        IOSDiscoveryRefreshResult(
            listing: nil,
            destinations: [],
            repair: IOSProfileRepair.resolve(
                saved: saved,
                listing: .failed,
                destinations: .failed
            ),
            errorMessage: IOSProjectDiscoveryError.cancelled.localizedDescription,
            listingLookup: .failed,
            destinationLookup: .failed
        )
    }

    private func candidateToQuery(path: String?) -> IOSProjectCandidate? {
        guard let path,
              FileManager.default.fileExists(atPath: path),
              let candidate = IOSProjectCandidate(path: path) else { return nil }
        return candidate
    }

    private func schemeForFollowup(saved: IOSProjectProfile, listing: IOSProjectListing) -> String? {
        if let scheme = saved.scheme, listing.schemes.contains(scheme) {
            return scheme
        }
        if saved.scheme == nil, listing.schemes.count == 1 {
            return listing.schemes[0]
        }
        return nil
    }

    private func runPreferringJSON(
        baseArguments: [String],
        timeout: TimeInterval,
        description: String
    ) async throws -> String {
        let jsonArguments = withJSONFlag(baseArguments)
        let jsonResult = try await runXcodebuildAllowingFailure(
            arguments: jsonArguments,
            timeout: timeout
        )
        if jsonResult.exitCode == 0 {
            return jsonResult.standardOutput
        }
        let fallback = try await runXcodebuild(
            arguments: baseArguments,
            timeout: timeout,
            description: description
        )
        return fallback.standardOutput
    }

    private func withJSONFlag(_ arguments: [String]) -> [String] {
        guard let index = arguments.firstIndex(where: { $0.hasPrefix("-") && !$0.hasPrefix("-json") }) else {
            return ["-json"] + arguments
        }
        var copy = arguments
        copy.insert("-json", at: index + 1)
        return copy
    }

    private func runXcodebuild(
        arguments: [String],
        timeout: TimeInterval,
        description: String
    ) async throws -> ProcessResult {
        let result = try await runXcodebuildAllowingFailure(
            arguments: arguments,
            timeout: timeout
        )
        guard result.exitCode == 0 else {
            throw IOSProjectDiscoveryError.commandFailed(
                description: description,
                exitCode: result.exitCode,
                stderr: result.standardError
            )
        }
        return result
    }

    private func runXcodebuildAllowingFailure(
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> ProcessResult {
        if Task.isCancelled { throw IOSProjectDiscoveryError.cancelled }
        let result: ProcessResult
        do {
            result = try await processRunner.run(
                executablePath: xcodebuildPath,
                arguments: arguments,
                workingDirectory: nil,
                deadline: Date().addingTimeInterval(timeout)
            )
        } catch let error as ProcessRunError {
            throw mapProcessError(error)
        }
        if result.standardOutputTruncated || result.standardErrorTruncated {
            throw IOSProjectDiscoveryError.outputTruncated
        }
        return result
    }

    private func mapProcessError(_ error: ProcessRunError) -> IOSProjectDiscoveryError {
        switch error {
        case .executableMissing(let path):
            return .executableMissing(path)
        case .timedOut:
            return .timedOut
        case .cancelled:
            return .cancelled
        case .launchFailed(let message):
            return .commandFailed(description: "xcodebuild", exitCode: -1, stderr: message)
        }
    }
}
