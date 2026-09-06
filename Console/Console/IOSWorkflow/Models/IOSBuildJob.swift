import Foundation

/// Lifecycle of one Console-owned iOS build or selected-test job.
nonisolated enum IOSBuildJobState: String, Equatable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled
    case timedOut

    var isTerminal: Bool {
        switch self {
        case .queued, .running:
            return false
        case .succeeded, .failed, .cancelled, .timedOut:
            return true
        }
    }

    var title: String {
        switch self {
        case .queued: return "Queued"
        case .running: return "Running"
        case .succeeded: return "Succeeded"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .timedOut: return "Timed Out"
        }
    }
}

nonisolated enum IOSBuildJobKind: String, Equatable, Sendable {
    case build
    case runSelectedTests
}

/// Explicit test filter. A job must name identifiers and/or a test plan —
/// never an implied whole-scheme / whole-UI-suite run.
nonisolated struct IOSTestSelection: Equatable, Sendable {
    var identifiers: [String]
    var testPlan: String?

    init(identifiers: [String] = [], testPlan: String? = nil) {
        self.identifiers = identifiers.compactMap(IOSProjectProfile.nilIfEmpty)
        self.testPlan = IOSProjectProfile.nilIfEmpty(testPlan)
    }

    var isExplicit: Bool {
        !identifiers.isEmpty || testPlan != nil
    }

    /// Uses the profile's saved test plan only when this selection is empty.
    /// Identifiers already count as an explicit choice and are not combined
    /// with a plan the caller did not request.
    func resolving(profile: IOSProjectProfile) -> IOSTestSelection {
        if isExplicit { return self }
        return IOSTestSelection(identifiers: [], testPlan: profile.testPlan)
    }
}

/// Configurable process deadline and `xcodebuild` test-runner timeout flags.
nonisolated struct IOSBuildTimeouts: Equatable, Sendable {
    var build: TimeInterval
    var test: TimeInterval
    var testTimeoutsEnabled: Bool
    var maximumTestExecutionTimeAllowance: TimeInterval
    var defaultTestExecutionTimeAllowance: TimeInterval?

    static let `default` = IOSBuildTimeouts(
        build: 600,
        test: 600,
        testTimeoutsEnabled: true,
        maximumTestExecutionTimeAllowance: 600,
        defaultTestExecutionTimeAllowance: nil
    )

    func duration(for kind: IOSBuildJobKind) -> TimeInterval {
        switch kind {
        case .build:
            return build
        case .runSelectedTests:
            return test
        }
    }
}

nonisolated enum IOSBuildRequestError: LocalizedError, Equatable {
    case missingProject
    case unsupportedProjectPath(String)
    case missingScheme
    case missingSimulator
    case missingTestSelection

    var errorDescription: String? {
        switch self {
        case .missingProject:
            return "Choose an Xcode project before building."
        case .unsupportedProjectPath(let path):
            return "“\(path)” is not an .xcodeproj or .xcworkspace."
        case .missingScheme:
            return "Choose a scheme before building."
        case .missingSimulator:
            return "Choose a Simulator before building."
        case .missingTestSelection:
            return "Choose a test plan or specific test identifiers. Console will not run a whole UI suite by default."
        }
    }
}

/// One Build or Run Selected Tests request. The profile is snapshotted at
/// enqueue and does not change if Settings is edited later. Success is the
/// process exit code plus structured result records, never a natural-language
/// summary. The `.xcresult` stays local.
nonisolated struct IOSBuildJob: Equatable, Identifiable, Sendable {
    let id: UUID
    let kind: IOSBuildJobKind
    let profile: IOSProjectProfile
    let testSelection: IOSTestSelection?
    let resultBundleURL: URL
    var state: IOSBuildJobState
    var createdAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var exitCode: Int32?
    var standardOutput: String
    var standardError: String
    var outputTruncated: Bool
    var errorMessage: String?
    var resultSummary: IOSResultSummary?

    var output: String {
        let parts = [standardOutput, standardError]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.joined(separator: "\n")
    }

    static func queued(
        id: UUID = UUID(),
        kind: IOSBuildJobKind,
        profile: IOSProjectProfile,
        testSelection: IOSTestSelection?,
        resultBundleURL: URL,
        createdAt: Date
    ) -> IOSBuildJob {
        IOSBuildJob(
            id: id,
            kind: kind,
            profile: profile,
            testSelection: testSelection,
            resultBundleURL: resultBundleURL,
            state: .queued,
            createdAt: createdAt,
            startedAt: nil,
            finishedAt: nil,
            exitCode: nil,
            standardOutput: "",
            standardError: "",
            outputTruncated: false,
            errorMessage: nil,
            resultSummary: nil
        )
    }

    /// Exit status and parsed result records determine the terminal state.
    /// Parser errors never promote a failure (or cancel/timeout) to success.
    static func resolvedState(
        processState: IOSBuildJobState,
        resultSummary: IOSResultSummary?
    ) -> IOSBuildJobState {
        switch processState {
        case .queued, .running, .cancelled, .timedOut, .failed:
            return processState
        case .succeeded:
            if resultSummary?.recordsIndicateFailure == true {
                return .failed
            }
            return .succeeded
        }
    }
}

/// Structured `xcodebuild` argv for iOS jobs. Executable plus argument array;
/// never `zsh -c`. No signing, provisioning, or upload flags.
nonisolated enum IOSXcodebuildCommand {
    static let defaultXcodebuildPath = "/usr/bin/xcodebuild"

    static func validateBuild(_ profile: IOSProjectProfile) throws {
        guard let projectPath = profile.projectPath else {
            throw IOSBuildRequestError.missingProject
        }
        guard IOSProjectCandidate(path: projectPath) != nil else {
            throw IOSBuildRequestError.unsupportedProjectPath(projectPath)
        }
        guard profile.scheme != nil else {
            throw IOSBuildRequestError.missingScheme
        }
        guard profile.simulatorUDID != nil else {
            throw IOSBuildRequestError.missingSimulator
        }
    }

    static func validateTest(_ profile: IOSProjectProfile, selection: IOSTestSelection) throws {
        try validateBuild(profile)
        guard selection.isExplicit else {
            throw IOSBuildRequestError.missingTestSelection
        }
    }

    static func makeLaunchSpec(
        kind: IOSBuildJobKind,
        profile: IOSProjectProfile,
        selection: IOSTestSelection?,
        resultBundleURL: URL,
        timeouts: IOSBuildTimeouts,
        xcodebuildPath: String = defaultXcodebuildPath
    ) throws -> ProcessLaunchSpec {
        try validateBuild(profile)
        if kind == .runSelectedTests {
            guard let selection, selection.isExplicit else {
                throw IOSBuildRequestError.missingTestSelection
            }
        }

        let projectPath = profile.projectPath!
        let candidate = IOSProjectCandidate(path: projectPath)!
        let scheme = profile.scheme!
        let udid = profile.simulatorUDID!

        var arguments: [String] = []
        switch kind {
        case .build:
            arguments.append("build")
        case .runSelectedTests:
            arguments.append("test")
        }

        switch candidate.kind {
        case .workspace:
            arguments.append(contentsOf: ["-workspace", candidate.path])
        case .project:
            arguments.append(contentsOf: ["-project", candidate.path])
        }

        arguments.append(contentsOf: ["-scheme", scheme])
        if let configuration = profile.configuration {
            arguments.append(contentsOf: ["-configuration", configuration])
        }
        arguments.append(contentsOf: [
            "-destination",
            "platform=iOS Simulator,id=\(udid)",
            "-resultBundlePath",
            resultBundleURL.path
        ])

        if kind == .runSelectedTests, let selection {
            if let testPlan = selection.testPlan {
                arguments.append(contentsOf: ["-testPlan", testPlan])
            }
            for identifier in selection.identifiers {
                arguments.append("-only-testing:\(identifier)")
            }
            if timeouts.testTimeoutsEnabled {
                arguments.append(contentsOf: [
                    "-test-timeouts-enabled",
                    "YES",
                    "-maximum-test-execution-time-allowance",
                    secondsFlag(timeouts.maximumTestExecutionTimeAllowance)
                ])
                if let defaultAllowance = timeouts.defaultTestExecutionTimeAllowance {
                    arguments.append(contentsOf: [
                        "-default-test-execution-time-allowance",
                        secondsFlag(defaultAllowance)
                    ])
                }
            }
        }

        let workingDirectory = URL(fileURLWithPath: candidate.path)
            .deletingLastPathComponent()
            .path
        return ProcessLaunchSpec(
            executablePath: xcodebuildPath,
            arguments: arguments,
            workingDirectory: workingDirectory
        )
    }

    static func secondsFlag(_ interval: TimeInterval) -> String {
        String(max(1, Int(interval.rounded(.up))))
    }
}
