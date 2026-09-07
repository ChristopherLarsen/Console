import Foundation

// MARK: - Simulator action results (package E)

/// Progress of one Ticket Work simulator prepare→wait→install→launch sequence.
/// Mirrors ``SimulatorInstallPhase`` without exposing IOSWorkflow UI strings as
/// durable workflow metadata.
nonisolated enum TicketWorkflowSimulatorPhase: String, Equatable, Sendable {
    case validatingInputs
    case resolvingProduct
    case preparingDevice
    case waitingForReady
    case installing
    case launching

    init(_ phase: SimulatorInstallPhase) {
        switch phase {
        case .resolvingProduct:
            self = .resolvingProduct
        case .listingDevices, .booting:
            self = .preparingDevice
        case .waitingForReady:
            self = .waitingForReady
        case .installing:
            self = .installing
        case .launching:
            self = .launching
        }
    }

    var title: String {
        switch self {
        case .validatingInputs:
            return "Checking Simulator selection…"
        case .resolvingProduct:
            return SimulatorInstallPhase.resolvingProduct.title
        case .preparingDevice:
            return "Preparing the selected Simulator…"
        case .waitingForReady:
            return SimulatorInstallPhase.waitingForReady.title
        case .installing:
            return SimulatorInstallPhase.installing.title
        case .launching:
            return SimulatorInstallPhase.launching.title
        }
    }
}

/// Which step of the sequence produced a failure. Used so Ticket Work can
/// surface the originating failure without rewriting SimulatorService.
nonisolated enum TicketWorkflowSimulatorFailureStep: String, Equatable, Sendable {
    case validatingInputs
    case resolvingProduct
    case preparingDevice
    case waitingForReady
    case installing
    case launching
    case cancelled

    init(_ phase: TicketWorkflowSimulatorPhase) {
        switch phase {
        case .validatingInputs: self = .validatingInputs
        case .resolvingProduct: self = .resolvingProduct
        case .preparingDevice: self = .preparingDevice
        case .waitingForReady: self = .waitingForReady
        case .installing: self = .installing
        case .launching: self = .launching
        }
    }
}

/// Successful prepare→install→launch. Local device/app identifiers only —
/// never ticket keys, titles, MR fields, or company URLs.
nonisolated struct TicketWorkflowSimulatorLaunchSuccess: Equatable, Sendable {
    var udid: String
    var deviceName: String
    var appURL: URL
    var bundleIdentifier: String
    var finishedAt: Date

    /// Launching the app never satisfies ``TicketStepRole/manualDeviceCheck``.
    /// That step remains developer acknowledgement.
    var completesManualDeviceCheck: Bool { false }

    init(
        udid: String,
        deviceName: String,
        appURL: URL,
        bundleIdentifier: String,
        finishedAt: Date = Date()
    ) {
        self.udid = udid
        self.deviceName = deviceName
        self.appURL = appURL
        self.bundleIdentifier = bundleIdentifier
        self.finishedAt = finishedAt
    }

    init(result: SimulatorLaunchResult, finishedAt: Date = Date()) {
        self.init(
            udid: result.udid,
            deviceName: result.deviceName,
            appURL: result.appURL,
            bundleIdentifier: result.bundleIdentifier,
            finishedAt: finishedAt
        )
    }
}

/// Failure (or cancellation) of a simulator step action. Message is a local
/// process/device diagnostic — never ticket/MR content.
nonisolated struct TicketWorkflowSimulatorFailure: Error, Equatable, Sendable {
    var step: TicketWorkflowSimulatorFailureStep
    var message: String
    var finishedAt: Date

    init(
        step: TicketWorkflowSimulatorFailureStep,
        message: String,
        finishedAt: Date = Date()
    ) {
        self.step = step
        self.message = message
        self.finishedAt = finishedAt
    }

    var errorDescription: String? { message }
}

/// Workflow-safe outcome of one simulator bridge action.
nonisolated enum TicketWorkflowSimulatorActionResult: Equatable, Sendable {
    /// App launched on the explicit UDID. Does **not** complete manual device check.
    case launched(TicketWorkflowSimulatorLaunchSuccess)
    case failed(TicketWorkflowSimulatorFailure)
    /// Console-owned wait/install/launch task was cancelled. Does not erase or
    /// shut down devices; only owned processes are stopped.
    case cancelled(TicketWorkflowSimulatorFailure)

    var failure: TicketWorkflowSimulatorFailure? {
        switch self {
        case .launched:
            return nil
        case .failed(let failure), .cancelled(let failure):
            return failure
        }
    }

    var launched: TicketWorkflowSimulatorLaunchSuccess? {
        if case .launched(let success) = self { return success }
        return nil
    }
}
