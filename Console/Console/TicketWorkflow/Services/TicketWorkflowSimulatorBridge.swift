import Foundation

/// Bridges ``SimulatorService`` into Ticket Work without owning a competing
/// device store or auto-completing the manual device-check step.
///
/// Sequence: validate explicit UDID → resolve/use exact app artifact → prepare
/// device → wait readiness → install → launch. Failures stop at the originating
/// step. Cancellation affects only Console-owned processes.
nonisolated struct TicketWorkflowSimulatorBridge {
    private let service: SimulatorService
    private let fileExists: @Sendable (String) -> Bool
    private let isDirectory: @Sendable (String) -> Bool

    nonisolated init(
        service: SimulatorService,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        isDirectory: (@Sendable (String) -> Bool)? = nil
    ) {
        self.service = service
        self.fileExists = fileExists
        self.isDirectory = isDirectory ?? { path in
            var directory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &directory)
            return exists && directory.boolValue
        }
    }

    nonisolated init(processRunner: any ProcessRunning) {
        self.init(service: SimulatorService(processRunner: processRunner))
    }

    // MARK: - Checklist outcome mapping

    /// Maps a bridge result for reducer wiring.
    ///
    /// - Launch success returns `nil`: ``TicketStepRole/manualDeviceCheck`` is
    ///   developer acknowledgement and must not become ``TicketStepOutcome/succeeded``.
    /// - Failures map to ``TicketStepOutcome/failed``.
    /// - Cancellation maps to ``TicketStepOutcome/interrupted``.
    static func checklistOutcome(
        for result: TicketWorkflowSimulatorActionResult
    ) -> TicketStepOutcome? {
        switch result {
        case .launched:
            return nil
        case .failed:
            return .failed
        case .cancelled:
            return .interrupted
        }
    }

    /// True only when the developer still must acknowledge the manual check
    /// after a successful launch (always true for `.launched`).
    static func requiresManualDeviceCheckAcknowledgement(
        for result: TicketWorkflowSimulatorActionResult
    ) -> Bool {
        if case .launched(let success) = result {
            return !success.completesManualDeviceCheck
        }
        return false
    }

    // MARK: - Actions

    /// Prepare→wait→install→launch using a successful build job's exact product
    /// (resolved from that job's build settings / Info.plist — never guessed).
    func prepareInstallAndLaunch(
        job: IOSBuildJob,
        selectedUDID: String?,
        progress: ((TicketWorkflowSimulatorPhase) -> Void)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) async -> TicketWorkflowSimulatorActionResult {
        progress?(.validatingInputs)
        guard let udid = Self.requireExplicitUDID(selectedUDID) else {
            return .failed(Self.missingUDIDFailure(at: now()))
        }
        guard job.state == .succeeded else {
            return .failed(
                TicketWorkflowSimulatorFailure(
                    step: .resolvingProduct,
                    message: SimulatorServiceError.failedBuild(job.state).localizedDescription,
                    finishedAt: now()
                )
            )
        }

        do {
            try Task.checkCancellation()
            progress?(.resolvingProduct)
            let product = try await service.resolveProduct(from: job)
            return await runSequence(
                artifact: product,
                udid: udid,
                progress: progress,
                now: now,
                reportResolvingPhase: false
            )
        } catch {
            return mapThrown(
                error,
                phase: .resolvingProduct,
                at: now()
            )
        }
    }

    /// Artifact-handoff path: install/launch the exact ``IOSBuiltProduct`` from
    /// a prior successful build. Does not re-discover apps under DerivedData.
    func prepareInstallAndLaunch(
        artifact: IOSBuiltProduct,
        selectedUDID: String?,
        progress: ((TicketWorkflowSimulatorPhase) -> Void)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) async -> TicketWorkflowSimulatorActionResult {
        progress?(.validatingInputs)
        guard let udid = Self.requireExplicitUDID(selectedUDID) else {
            return .failed(Self.missingUDIDFailure(at: now()))
        }
        return await runSequence(
            artifact: artifact,
            udid: udid,
            progress: progress,
            now: now,
            reportResolvingPhase: true
        )
    }

    /// Opens the Simulator.app window for the explicit UDID only. Does not
    /// install, launch an app product, or complete the manual device-check step.
    func openSimulatorApp(
        selectedUDID: String?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) async -> Result<String, TicketWorkflowSimulatorFailure> {
        guard let udid = Self.requireExplicitUDID(selectedUDID) else {
            return .failure(Self.missingUDIDFailure(at: now()))
        }
        do {
            try Task.checkCancellation()
            try await service.openSimulator(udid: udid)
            return .success(udid)
        } catch is CancellationError {
            return .failure(
                TicketWorkflowSimulatorFailure(
                    step: .cancelled,
                    message: SimulatorServiceError.cancelled.localizedDescription,
                    finishedAt: now()
                )
            )
        } catch let error as SimulatorServiceError where error == .cancelled {
            return .failure(
                TicketWorkflowSimulatorFailure(
                    step: .cancelled,
                    message: error.localizedDescription,
                    finishedAt: now()
                )
            )
        } catch {
            return .failure(
                TicketWorkflowSimulatorFailure(
                    step: .preparingDevice,
                    message: error.localizedDescription,
                    finishedAt: now()
                )
            )
        }
    }

    // MARK: - Sequence

    private func runSequence(
        artifact: IOSBuiltProduct,
        udid: String,
        progress: ((TicketWorkflowSimulatorPhase) -> Void)?,
        now: @escaping @Sendable () -> Date,
        reportResolvingPhase: Bool
    ) async -> TicketWorkflowSimulatorActionResult {
        var phase: TicketWorkflowSimulatorPhase = .resolvingProduct
        do {
            try Task.checkCancellation()
            phase = .resolvingProduct
            if reportResolvingPhase {
                progress?(phase)
            }
            try validateArtifact(artifact)

            try Task.checkCancellation()
            phase = .preparingDevice
            progress?(phase)
            let devices = try await service.listDevices()
            let device = try service.requireAvailableDevice(udid: udid, in: devices)
            try await service.bootIfNeeded(device) { installPhase in
                progress?(TicketWorkflowSimulatorPhase(installPhase))
            }

            try Task.checkCancellation()
            phase = .waitingForReady
            progress?(phase)
            try await service.waitUntilReady(udid: device.udid)

            try Task.checkCancellation()
            phase = .installing
            progress?(phase)
            try await service.install(udid: device.udid, appURL: artifact.appURL)

            try Task.checkCancellation()
            phase = .launching
            progress?(phase)
            try await service.launch(
                udid: device.udid,
                bundleIdentifier: artifact.bundleIdentifier
            )

            return .launched(
                TicketWorkflowSimulatorLaunchSuccess(
                    udid: device.udid,
                    deviceName: device.name,
                    appURL: artifact.appURL,
                    bundleIdentifier: artifact.bundleIdentifier,
                    finishedAt: now()
                )
            )
        } catch {
            return mapThrown(error, phase: phase, at: now())
        }
    }

    private func validateArtifact(_ artifact: IOSBuiltProduct) throws {
        let path = artifact.appURL.path
        guard isDirectory(path) || fileExists(path) else {
            throw SimulatorServiceError.missingApp(path)
        }
        guard IOSProjectProfile.nilIfEmpty(artifact.bundleIdentifier) != nil else {
            throw SimulatorServiceError.productLookupFailed(
                "the build artifact has no bundle identifier."
            )
        }
    }

    // MARK: - Mapping helpers

    private static func requireExplicitUDID(_ udid: String?) -> String? {
        IOSProjectProfile.nilIfEmpty(udid)
    }

    private static func missingUDIDFailure(at date: Date) -> TicketWorkflowSimulatorFailure {
        TicketWorkflowSimulatorFailure(
            step: .validatingInputs,
            message: SimulatorServiceError.missingSimulator.localizedDescription,
            finishedAt: date
        )
    }

    private func mapThrown(
        _ error: Error,
        phase: TicketWorkflowSimulatorPhase,
        at date: Date
    ) -> TicketWorkflowSimulatorActionResult {
        if error is CancellationError {
            return .cancelled(
                TicketWorkflowSimulatorFailure(
                    step: .cancelled,
                    message: SimulatorServiceError.cancelled.localizedDescription,
                    finishedAt: date
                )
            )
        }
        if let serviceError = error as? SimulatorServiceError {
            return mapServiceError(serviceError, phase: phase, at: date)
        }
        return .failed(
            TicketWorkflowSimulatorFailure(
                step: TicketWorkflowSimulatorFailureStep(phase),
                message: error.localizedDescription,
                finishedAt: date
            )
        )
    }

    private func mapServiceError(
        _ error: SimulatorServiceError,
        phase: TicketWorkflowSimulatorPhase,
        at date: Date
    ) -> TicketWorkflowSimulatorActionResult {
        switch error {
        case .cancelled:
            return .cancelled(
                TicketWorkflowSimulatorFailure(
                    step: .cancelled,
                    message: error.localizedDescription,
                    finishedAt: date
                )
            )
        case .missingSimulator:
            return .failed(
                TicketWorkflowSimulatorFailure(
                    step: .validatingInputs,
                    message: error.localizedDescription,
                    finishedAt: date
                )
            )
        case .failedBuild, .missingApp, .productLookupFailed:
            return .failed(
                TicketWorkflowSimulatorFailure(
                    step: .resolvingProduct,
                    message: error.localizedDescription,
                    finishedAt: date
                )
            )
        case .deviceNotFound, .unavailableRuntime, .unexpectedDeviceState, .bootFailed:
            return .failed(
                TicketWorkflowSimulatorFailure(
                    step: .preparingDevice,
                    message: error.localizedDescription,
                    finishedAt: date
                )
            )
        case .bootTimedOut:
            return .failed(
                TicketWorkflowSimulatorFailure(
                    step: .waitingForReady,
                    message: error.localizedDescription,
                    finishedAt: date
                )
            )
        case .installFailed:
            return .failed(
                TicketWorkflowSimulatorFailure(
                    step: .installing,
                    message: error.localizedDescription,
                    finishedAt: date
                )
            )
        case .launchFailed:
            return .failed(
                TicketWorkflowSimulatorFailure(
                    step: .launching,
                    message: error.localizedDescription,
                    finishedAt: date
                )
            )
        case .timedOut, .commandFailed, .executableMissing, .invalidJSON, .outputTruncated:
            return .failed(
                TicketWorkflowSimulatorFailure(
                    step: TicketWorkflowSimulatorFailureStep(phase),
                    message: error.localizedDescription,
                    finishedAt: date
                )
            )
        }
    }
}
