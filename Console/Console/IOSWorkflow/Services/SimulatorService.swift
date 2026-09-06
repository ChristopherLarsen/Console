import Foundation

/// Structured `xcrun simctl` argv. Executable plus argument array; never
/// `zsh -c`. Never erase, shutdown, delete, or otherwise mutate a device
/// other than the explicit UDID being installed.
nonisolated enum SimctlCommand {
    static let defaultXcrunPath = "/usr/bin/xcrun"
    static let defaultOpenPath = "/usr/bin/open"
    static let simulatorAppName = "Simulator"

    /// Subcommands that would affect other devices. Console never emits these.
    static let forbiddenSubcommands: Set<String> = [
        "erase",
        "shutdown",
        "delete",
        "deleteunavailable",
        "upgrade",
        "clone",
        "create",
        "rename",
        "pair",
        "unpair",
        "addphoto",
        "addvideo",
        "privacy",
        "keychain",
        "spawn",
        "terminate",
        "uninstall"
    ]

    static func listDevices(xcrunPath: String = defaultXcrunPath) -> ProcessLaunchSpec {
        ProcessLaunchSpec(
            executablePath: xcrunPath,
            arguments: ["simctl", "list", "devices", "--json"],
            workingDirectory: nil
        )
    }

    static func boot(udid: String, xcrunPath: String = defaultXcrunPath) -> ProcessLaunchSpec {
        ProcessLaunchSpec(
            executablePath: xcrunPath,
            arguments: ["simctl", "boot", udid],
            workingDirectory: nil
        )
    }

    static func bootStatus(udid: String, xcrunPath: String = defaultXcrunPath) -> ProcessLaunchSpec {
        ProcessLaunchSpec(
            executablePath: xcrunPath,
            arguments: ["simctl", "bootstatus", udid],
            workingDirectory: nil
        )
    }

    static func install(udid: String, appPath: String, xcrunPath: String = defaultXcrunPath) -> ProcessLaunchSpec {
        ProcessLaunchSpec(
            executablePath: xcrunPath,
            arguments: ["simctl", "install", udid, appPath],
            workingDirectory: nil
        )
    }

    static func launch(
        udid: String,
        bundleIdentifier: String,
        xcrunPath: String = defaultXcrunPath
    ) -> ProcessLaunchSpec {
        ProcessLaunchSpec(
            executablePath: xcrunPath,
            arguments: ["simctl", "launch", udid, bundleIdentifier],
            workingDirectory: nil
        )
    }

    static func openSimulatorApp(
        udid: String,
        openPath: String = defaultOpenPath
    ) -> ProcessLaunchSpec {
        ProcessLaunchSpec(
            executablePath: openPath,
            arguments: ["-a", simulatorAppName, "--args", "-CurrentDeviceUDID", udid],
            workingDirectory: nil
        )
    }
}

/// `xcodebuild -showBuildSettings` for the snapshotted profile. Product path
/// and bundle ID come from these settings plus Info.plist, never from guessing
/// app names under DerivedData.
nonisolated enum IOSBuildSettingsCommand {
    static func makeLaunchSpec(
        profile: IOSProjectProfile,
        json: Bool,
        xcodebuildPath: String = IOSXcodebuildCommand.defaultXcodebuildPath
    ) throws -> ProcessLaunchSpec {
        try IOSXcodebuildCommand.validateBuild(profile)
        let projectPath = profile.projectPath!
        let candidate = IOSProjectCandidate(path: projectPath)!
        let scheme = profile.scheme!
        let udid = profile.simulatorUDID!

        var arguments: [String] = ["-showBuildSettings"]
        if json {
            arguments.append("-json")
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
            "platform=iOS Simulator,id=\(udid)"
        ])

        let workingDirectory = URL(fileURLWithPath: candidate.path)
            .deletingLastPathComponent()
            .path
        return ProcessLaunchSpec(
            executablePath: xcodebuildPath,
            arguments: arguments,
            workingDirectory: workingDirectory
        )
    }
}

/// Parses `simctl list devices --json`.
nonisolated enum SimulatorDeviceListParser {
    static func devices(from output: String) throws -> [SimulatorDevice] {
        guard let data = jsonData(in: output) else {
            throw SimulatorServiceError.invalidJSON("missing JSON object")
        }
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw SimulatorServiceError.invalidJSON(error.localizedDescription)
        }
        guard let dictionary = root as? [String: Any] else {
            throw SimulatorServiceError.invalidJSON("root was not an object")
        }
        let groups = dictionary["devices"] as? [String: Any] ?? [:]
        var devices: [SimulatorDevice] = []
        for (runtimeKey, value) in groups {
            guard isIOSRuntime(runtimeKey) else { continue }
            let runtimeUnavailable = runtimeKey.localizedCaseInsensitiveContains("unavailable")
            let items = value as? [Any] ?? []
            let runtimeName = displayRuntimeName(runtimeKey)
            for item in items {
                guard let dict = item as? [String: Any] else { continue }
                guard let udid = IOSProjectProfile.nilIfEmpty(dict["udid"] as? String) else { continue }
                let name = IOSProjectProfile.nilIfEmpty(dict["name"] as? String) ?? udid
                let rawState = (dict["state"] as? String) ?? ""
                let availabilityError = IOSProjectProfile.nilIfEmpty(dict["availabilityError"] as? String)
                let isAvailable: Bool
                if let flag = dict["isAvailable"] as? Bool {
                    isAvailable = flag && !runtimeUnavailable
                } else {
                    isAvailable = !runtimeUnavailable && availabilityError == nil
                }
                devices.append(
                    SimulatorDevice(
                        udid: udid,
                        name: name,
                        state: SimulatorDeviceState(simctlValue: rawState),
                        isAvailable: isAvailable,
                        runtimeIdentifier: runtimeKey,
                        runtimeName: runtimeName,
                        availabilityError: availabilityError
                    )
                )
            }
        }
        return devices.sorted { lhs, rhs in
            if lhs.runtimeName != rhs.runtimeName {
                return lhs.runtimeName.localizedStandardCompare(rhs.runtimeName) == .orderedAscending
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func jsonData(in output: String) -> Data? {
        if let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}") {
            return String(output[start...end]).data(using: .utf8)
        }
        return nil
    }

    static func isIOSRuntime(_ key: String) -> Bool {
        let lowered = key.lowercased()
        if lowered.contains("watchos") || lowered.contains("tvos") || lowered.contains("xros")
            || lowered.contains("visionos") || lowered.contains("macos") {
            return false
        }
        return lowered.contains("ios")
    }

    static func displayRuntimeName(_ key: String) -> String {
        var trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: " (unavailable)", options: .caseInsensitive) {
            trimmed.removeSubrange(range)
        }
        let prefix = "com.apple.CoreSimulator.SimRuntime."
        if trimmed.hasPrefix(prefix) {
            let suffix = String(trimmed.dropFirst(prefix.count))
            let parts = suffix.split(separator: "-").map(String.init)
            if parts.count >= 2 {
                return "\(parts[0]) \(parts.dropFirst().joined(separator: "."))"
            }
            return suffix.replacingOccurrences(of: "-", with: " ")
        }
        return trimmed
    }
}

/// Parses `xcodebuild -showBuildSettings` JSON or text into the scheme's `.app`.
nonisolated enum IOSBuildSettingsParser {
    struct TargetSettings: Equatable, Sendable {
        var targetName: String?
        var settings: [String: String]

        var wrapperExtension: String? {
            IOSProjectProfile.nilIfEmpty(settings["WRAPPER_EXTENSION"])
        }

        var productBundleIdentifier: String? {
            IOSProjectProfile.nilIfEmpty(settings["PRODUCT_BUNDLE_IDENTIFIER"])
        }

        var appPath: String? {
            if let path = IOSProjectProfile.nilIfEmpty(settings["CODESIGNING_FOLDER_PATH"]),
               path.hasSuffix(".app") {
                return path
            }
            let name = IOSProjectProfile.nilIfEmpty(settings["WRAPPER_NAME"])
                ?? IOSProjectProfile.nilIfEmpty(settings["FULL_PRODUCT_NAME"])
            let directory = IOSProjectProfile.nilIfEmpty(settings["TARGET_BUILD_DIR"])
                ?? IOSProjectProfile.nilIfEmpty(settings["BUILT_PRODUCTS_DIR"])
            guard let directory, let name, name.hasSuffix(".app") else { return nil }
            return URL(fileURLWithPath: directory).appendingPathComponent(name).path
        }

        var isSimulatorApp: Bool {
            guard appPath != nil else { return false }
            if let wrapperExtension {
                return wrapperExtension == "app"
            }
            return true
        }
    }

    static func product(from output: String, scheme: String) throws -> (appPath: String, bundleID: String, targetName: String?) {
        let targets = parseTargets(from: output)
        let apps = targets.filter(\.isSimulatorApp)
        guard !apps.isEmpty else {
            throw SimulatorServiceError.productLookupFailed(
                "build settings did not include an .app product for scheme “\(scheme)”."
            )
        }

        let chosen: TargetSettings
        if let matching = apps.first(where: { $0.targetName == scheme }) {
            chosen = matching
        } else if apps.count == 1 {
            chosen = apps[0]
        } else {
            throw SimulatorServiceError.productLookupFailed(
                "build settings listed multiple .app products; Console will not guess which one to install."
            )
        }

        guard let appPath = chosen.appPath else {
            throw SimulatorServiceError.productLookupFailed("the selected target has no .app path.")
        }
        let bundleID = chosen.productBundleIdentifier ?? ""
        return (appPath, bundleID, chosen.targetName)
    }

    static func parseTargets(from output: String) -> [TargetSettings] {
        if let data = jsonData(in: output),
           let value = try? JSONSerialization.jsonObject(with: data) {
            let parsed = targets(fromJSON: value)
            if !parsed.isEmpty { return parsed }
        }
        return targets(fromText: output)
    }

    private static func jsonData(in output: String) -> Data? {
        if let start = output.firstIndex(of: "["), let end = output.lastIndex(of: "]"),
           (output.firstIndex(of: "{") == nil || start < output.firstIndex(of: "{")!) {
            return String(output[start...end]).data(using: .utf8)
        }
        if let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}") {
            return String(output[start...end]).data(using: .utf8)
        }
        return nil
    }

    private static func targets(fromJSON value: Any) -> [TargetSettings] {
        let items: [Any]
        if let array = value as? [Any] {
            items = array
        } else if let dict = value as? [String: Any] {
            items = (dict["buildSettings"] as? [Any])
                ?? (dict["targets"] as? [Any])
                ?? [dict]
        } else {
            items = []
        }
        return items.compactMap { item in
            guard let dict = item as? [String: Any] else { return nil }
            let settingsObject = dict["buildSettings"] as? [String: Any] ?? dict
            var settings: [String: String] = [:]
            for (key, raw) in settingsObject {
                if let string = raw as? String {
                    settings[key] = string
                } else if let number = raw as? NSNumber {
                    settings[key] = number.stringValue
                }
            }
            guard !settings.isEmpty else { return nil }
            let name = (dict["target"] as? String)
                ?? (dict["targetName"] as? String)
                ?? settings["TARGETNAME"]
            return TargetSettings(targetName: IOSProjectProfile.nilIfEmpty(name), settings: settings)
        }
    }

    private static func targets(fromText output: String) -> [TargetSettings] {
        var results: [TargetSettings] = []
        var currentName: String?
        var current: [String: String] = [:]

        func flush() {
            guard !current.isEmpty else { return }
            results.append(TargetSettings(targetName: currentName, settings: current))
            current = [:]
            currentName = nil
        }

        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("build settings for") {
                flush()
                currentName = targetName(fromHeader: trimmed)
                continue
            }
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            current[key] = value
        }
        flush()
        return results
    }

    private static func targetName(fromHeader header: String) -> String? {
        if let start = header.firstIndex(of: "\""),
           let end = header[header.index(after: start)...].firstIndex(of: "\"") {
            return IOSProjectProfile.nilIfEmpty(String(header[header.index(after: start)..<end]))
        }
        return nil
    }
}

nonisolated enum SimulatorInfoPlist {
    static func bundleIdentifier(atAppURL url: URL) -> String? {
        let plistURL = url.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = IOSProjectProfile.nilIfEmpty(object["CFBundleIdentifier"] as? String)
        else {
            return nil
        }
        if identifier.contains("$(") || identifier.contains("${") {
            return nil
        }
        return identifier
    }
}

/// Lists, boots, installs, and launches one explicit Simulator UDID using
/// structured `xcrun simctl` calls. Product path and bundle ID come from
/// build settings and Info.plist. Other devices are never erased or shut down.
nonisolated struct SimulatorService {
    nonisolated static let listTimeout: TimeInterval = 15
    nonisolated static let bootTimeout: TimeInterval = 30
    nonisolated static let bootStatusTimeout: TimeInterval = 90
    nonisolated static let installTimeout: TimeInterval = 60
    nonisolated static let launchTimeout: TimeInterval = 30
    nonisolated static let openTimeout: TimeInterval = 15
    nonisolated static let buildSettingsTimeout: TimeInterval = 45

    private let processRunner: any ProcessRunning
    private let xcrunPath: String
    private let xcodebuildPath: String
    private let openPath: String
    private let fileExists: @Sendable (String) -> Bool
    private let isDirectory: @Sendable (String) -> Bool

    nonisolated init(
        processRunner: any ProcessRunning,
        xcrunPath: String = SimctlCommand.defaultXcrunPath,
        xcodebuildPath: String = IOSXcodebuildCommand.defaultXcodebuildPath,
        openPath: String = SimctlCommand.defaultOpenPath,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        isDirectory: (@Sendable (String) -> Bool)? = nil
    ) {
        self.processRunner = processRunner
        self.xcrunPath = xcrunPath
        self.xcodebuildPath = xcodebuildPath
        self.openPath = openPath
        self.fileExists = fileExists
        self.isDirectory = isDirectory ?? { path in
            var directory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &directory)
            return exists && directory.boolValue
        }
    }

    func listDevices() async throws -> [SimulatorDevice] {
        let spec = SimctlCommand.listDevices(xcrunPath: xcrunPath)
        let result = try await run(spec, timeout: Self.listTimeout, description: "simctl list")
        return try SimulatorDeviceListParser.devices(from: result.standardOutput)
    }

    func resolveProduct(from job: IOSBuildJob) async throws -> IOSBuiltProduct {
        guard job.state == .succeeded else {
            throw SimulatorServiceError.failedBuild(job.state)
        }
        try Task.checkCancellation()
        let spec = try IOSBuildSettingsCommand.makeLaunchSpec(
            profile: job.profile,
            json: true,
            xcodebuildPath: xcodebuildPath
        )
        let jsonResult = try await runAllowingFailure(spec, timeout: Self.buildSettingsTimeout)
        let output: String
        if jsonResult.exitCode == 0 {
            output = jsonResult.standardOutput
        } else {
            let textSpec = try IOSBuildSettingsCommand.makeLaunchSpec(
                profile: job.profile,
                json: false,
                xcodebuildPath: xcodebuildPath
            )
            let textResult = try await run(
                textSpec,
                timeout: Self.buildSettingsTimeout,
                description: "xcodebuild -showBuildSettings"
            )
            output = textResult.standardOutput
        }

        let scheme = job.profile.scheme ?? ""
        let parsed = try IOSBuildSettingsParser.product(from: output, scheme: scheme)
        let appURL = URL(fileURLWithPath: parsed.appPath, isDirectory: true)
        guard isDirectory(parsed.appPath) || fileExists(parsed.appPath) else {
            throw SimulatorServiceError.missingApp(parsed.appPath)
        }
        let plistIdentifier = SimulatorInfoPlist.bundleIdentifier(atAppURL: appURL)
        let bundleID = IOSProjectProfile.nilIfEmpty(plistIdentifier)
            ?? IOSProjectProfile.nilIfEmpty(parsed.bundleID)
        guard let bundleID else {
            throw SimulatorServiceError.productLookupFailed(
                "Info.plist and build settings both lacked a bundle identifier."
            )
        }
        return IOSBuiltProduct(appURL: appURL, bundleIdentifier: bundleID, targetName: parsed.targetName)
    }

    /// List → boot if needed → bootstatus → install → launch for `udid` only.
    func installAndLaunch(
        job: IOSBuildJob,
        udid: String,
        progress: ((SimulatorInstallPhase) -> Void)? = nil
    ) async throws -> SimulatorLaunchResult {
        do {
            return try await runInstallAndLaunch(job: job, udid: udid, progress: progress)
        } catch is CancellationError {
            throw SimulatorServiceError.cancelled
        }
    }

    private func runInstallAndLaunch(
        job: IOSBuildJob,
        udid: String,
        progress: ((SimulatorInstallPhase) -> Void)?
    ) async throws -> SimulatorLaunchResult {
        let trimmedUDID = try requireUDID(udid)
        try Task.checkCancellation()
        progress?(.resolvingProduct)
        let product = try await resolveProduct(from: job)

        try Task.checkCancellation()
        progress?(.listingDevices)
        let devices = try await listDevices()
        let device = try requireAvailableDevice(udid: trimmedUDID, in: devices)

        try await bootIfNeeded(device, progress: progress)
        try Task.checkCancellation()
        progress?(.waitingForReady)
        try await waitUntilReady(udid: device.udid)

        try Task.checkCancellation()
        progress?(.installing)
        try await install(udid: device.udid, appURL: product.appURL)

        try Task.checkCancellation()
        progress?(.launching)
        try await launch(udid: device.udid, bundleIdentifier: product.bundleIdentifier)

        return SimulatorLaunchResult(
            udid: device.udid,
            deviceName: device.name,
            appURL: product.appURL,
            bundleIdentifier: product.bundleIdentifier
        )
    }

    func openSimulator(udid: String) async throws {
        let trimmedUDID = try requireUDID(udid)
        let spec = SimctlCommand.openSimulatorApp(udid: trimmedUDID, openPath: openPath)
        _ = try await run(spec, timeout: Self.openTimeout, description: "open Simulator")
    }

    func bootIfNeeded(_ device: SimulatorDevice, progress: ((SimulatorInstallPhase) -> Void)? = nil) async throws {
        switch device.state {
        case .booted, .booting:
            return
        case .shutdown:
            progress?(.booting)
            try await boot(udid: device.udid)
        case .shuttingDown, .creating, .unknown:
            throw SimulatorServiceError.unexpectedDeviceState(udid: device.udid, state: device.state)
        }
    }

    func boot(udid: String) async throws {
        let spec = SimctlCommand.boot(udid: udid, xcrunPath: xcrunPath)
        let result = try await runAllowingFailure(spec, timeout: Self.bootTimeout)
        if result.exitCode == 0 { return }
        let stderr = result.standardError
        if stderr.localizedCaseInsensitiveContains("current state: Booted")
            || stderr.localizedCaseInsensitiveContains("already booted") {
            return
        }
        throw SimulatorServiceError.bootFailed(failureDetail(result))
    }

    func waitUntilReady(udid: String) async throws {
        let spec = SimctlCommand.bootStatus(udid: udid, xcrunPath: xcrunPath)
        do {
            _ = try await run(spec, timeout: Self.bootStatusTimeout, description: "simctl bootstatus")
        } catch let error as SimulatorServiceError {
            if case .timedOut = error {
                throw SimulatorServiceError.bootTimedOut(udid)
            }
            throw error
        }
    }

    func install(udid: String, appURL: URL) async throws {
        let spec = SimctlCommand.install(udid: udid, appPath: appURL.path, xcrunPath: xcrunPath)
        let result = try await runAllowingFailure(spec, timeout: Self.installTimeout)
        guard result.exitCode == 0 else {
            throw SimulatorServiceError.installFailed(failureDetail(result))
        }
    }

    func launch(udid: String, bundleIdentifier: String) async throws {
        let spec = SimctlCommand.launch(
            udid: udid,
            bundleIdentifier: bundleIdentifier,
            xcrunPath: xcrunPath
        )
        let result = try await runAllowingFailure(spec, timeout: Self.launchTimeout)
        guard result.exitCode == 0 else {
            throw SimulatorServiceError.launchFailed(failureDetail(result))
        }
    }

    func requireAvailableDevice(udid: String, in devices: [SimulatorDevice]) throws -> SimulatorDevice {
        guard let device = devices.first(where: { $0.udid == udid }) else {
            throw SimulatorServiceError.deviceNotFound(udid)
        }
        if !device.isAvailable {
            throw SimulatorServiceError.unavailableRuntime(
                udid: device.udid,
                name: device.name,
                detail: device.availabilityError
            )
        }
        return device
    }

    private func requireUDID(_ udid: String) throws -> String {
        guard let trimmed = IOSProjectProfile.nilIfEmpty(udid) else {
            throw SimulatorServiceError.missingSimulator
        }
        return trimmed
    }

    private func failureDetail(_ result: ProcessResult) -> String {
        let stderr = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        let stdout = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdout.isEmpty { return stdout }
        return "exit code \(result.exitCode)"
    }

    private func run(
        _ spec: ProcessLaunchSpec,
        timeout: TimeInterval,
        description: String
    ) async throws -> ProcessResult {
        let result = try await runAllowingFailure(spec, timeout: timeout)
        guard result.exitCode == 0 else {
            throw SimulatorServiceError.commandFailed(
                description: description,
                exitCode: result.exitCode,
                stderr: result.standardError
            )
        }
        return result
    }

    private func runAllowingFailure(
        _ spec: ProcessLaunchSpec,
        timeout: TimeInterval
    ) async throws -> ProcessResult {
        try Task.checkCancellation()
        assertNoForbiddenSubcommand(spec)
        do {
            let result = try await processRunner.run(
                executablePath: spec.executablePath,
                arguments: spec.arguments,
                workingDirectory: spec.workingDirectory,
                deadline: Date().addingTimeInterval(timeout)
            )
            if result.standardOutputTruncated || result.standardErrorTruncated {
                throw SimulatorServiceError.outputTruncated
            }
            return result
        } catch is CancellationError {
            throw SimulatorServiceError.cancelled
        } catch let error as ProcessRunError {
            throw mapProcessError(error, spec: spec)
        }
    }

    private func assertNoForbiddenSubcommand(_ spec: ProcessLaunchSpec) {
        guard spec.arguments.first == "simctl", spec.arguments.count >= 2 else { return }
        precondition(
            !SimctlCommand.forbiddenSubcommands.contains(spec.arguments[1]),
            "SimulatorService must never invoke simctl \(spec.arguments[1])"
        )
    }

    private func mapProcessError(_ error: ProcessRunError, spec: ProcessLaunchSpec) -> SimulatorServiceError {
        switch error {
        case .executableMissing(let path):
            return .executableMissing(path)
        case .timedOut:
            if spec.arguments.contains("bootstatus") {
                let udid = spec.arguments.last(where: { $0 != "bootstatus" && $0 != "simctl" }) ?? "selected"
                return .bootTimedOut(udid)
            }
            let description = spec.arguments.first == "simctl"
                ? "simctl \(spec.arguments.dropFirst().first ?? "")"
                : URL(fileURLWithPath: spec.executablePath).lastPathComponent
            return .timedOut(description)
        case .cancelled:
            return .cancelled
        case .launchFailed(let message):
            return .commandFailed(description: spec.executablePath, exitCode: -1, stderr: message)
        }
    }
}