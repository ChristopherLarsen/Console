import Foundation

/// One CoreSimulator device from `simctl list`, never inferred from whichever
/// device happens to be booted.
nonisolated struct SimulatorDevice: Equatable, Sendable, Identifiable {
    var id: String { udid }
    var udid: String
    var name: String
    var state: SimulatorDeviceState
    var isAvailable: Bool
    var runtimeIdentifier: String
    var runtimeName: String
    var availabilityError: String?

    var displayName: String {
        if runtimeName.isEmpty {
            return name
        }
        return "\(name) · \(runtimeName)"
    }

    var needsBoot: Bool {
        state == .shutdown
    }

    var isReady: Bool {
        state == .booted
    }
}

nonisolated enum SimulatorDeviceState: String, Equatable, Sendable {
    case booted
    case shutdown
    case booting
    case shuttingDown
    case creating
    case unknown

    init(simctlValue: String) {
        switch simctlValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "booted":
            self = .booted
        case "shutdown":
            self = .shutdown
        case "booting":
            self = .booting
        case "shutting down", "shuttingdown":
            self = .shuttingDown
        case "creating":
            self = .creating
        default:
            self = .unknown
        }
    }

    var title: String {
        switch self {
        case .booted: return "Booted"
        case .shutdown: return "Shutdown"
        case .booting: return "Booting"
        case .shuttingDown: return "Shutting Down"
        case .creating: return "Creating"
        case .unknown: return "Unknown"
        }
    }
}

/// Progress of one explicit UDID install/launch sequence.
nonisolated enum SimulatorInstallPhase: String, Equatable, Sendable {
    case resolvingProduct
    case listingDevices
    case booting
    case waitingForReady
    case installing
    case launching

    var title: String {
        switch self {
        case .resolvingProduct: return "Finding the built app…"
        case .listingDevices: return "Listing Simulators…"
        case .booting: return "Booting the selected Simulator…"
        case .waitingForReady: return "Waiting for the Simulator to be ready…"
        case .installing: return "Installing the app…"
        case .launching: return "Launching the app…"
        }
    }
}

nonisolated struct SimulatorLaunchResult: Equatable, Sendable {
    var udid: String
    var deviceName: String
    var appURL: URL
    var bundleIdentifier: String
}

nonisolated struct IOSBuiltProduct: Equatable, Sendable {
    var appURL: URL
    var bundleIdentifier: String
    var targetName: String?
}

nonisolated enum SimulatorServiceError: LocalizedError, Equatable {
    case failedBuild(IOSBuildJobState)
    case missingApp(String)
    case missingSimulator
    case deviceNotFound(String)
    case unavailableRuntime(udid: String, name: String, detail: String?)
    case unexpectedDeviceState(udid: String, state: SimulatorDeviceState)
    case bootFailed(String)
    case bootTimedOut(String)
    case installFailed(String)
    case launchFailed(String)
    case productLookupFailed(String)
    case cancelled
    case executableMissing(String)
    case timedOut(String)
    case commandFailed(description: String, exitCode: Int32, stderr: String)
    case invalidJSON(String)
    case outputTruncated

    var errorDescription: String? {
        switch self {
        case .failedBuild(let state):
            return "The selected job did not succeed (\(state.title)). Install requires a successful build."
        case .missingApp(let path):
            return "The built app was not found at \(path)."
        case .missingSimulator:
            return "Choose a Simulator before installing. Console will not use whichever device happens to be booted."
        case .deviceNotFound(let udid):
            return "Simulator \(udid) is not in the device list. Console will not fall back to a booted device."
        case .unavailableRuntime(let udid, let name, let detail):
            if let detail, !detail.isEmpty {
                return "The runtime for \(name) (\(udid)) is unavailable: \(detail)."
            }
            return "The runtime for \(name) (\(udid)) is unavailable."
        case .unexpectedDeviceState(let udid, let state):
            return "Simulator \(udid) is \(state.title.lowercased()), so it cannot be booted or used yet."
        case .bootFailed(let detail):
            return "Could not boot the selected Simulator: \(detail)"
        case .bootTimedOut(let udid):
            return "Timed out waiting for Simulator \(udid) to become ready."
        case .installFailed(let detail):
            return "Installing the app on the selected Simulator failed: \(detail)"
        case .launchFailed(let detail):
            return "Launching the app on the selected Simulator failed: \(detail)"
        case .productLookupFailed(let detail):
            return "Could not determine the built app from build settings: \(detail)"
        case .cancelled:
            return "Waiting for the Simulator was cancelled."
        case .executableMissing(let path):
            return "Required tool was not found at \(path)."
        case .timedOut(let description):
            return "\(description) timed out."
        case .commandFailed(let description, let exitCode, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "\(description) failed (exit code \(exitCode))."
                : "\(description) failed (exit code \(exitCode)): \(detail)"
        case .invalidJSON:
            return "Simulator listing could not be parsed."
        case .outputTruncated:
            return "Simulator command output was truncated before it could be parsed."
        }
    }
}
