import Foundation

/// Settings → iOS Jobs simulator sibling: explicit UDID, Open Simulator, and
/// install/launch of the selected successful job's `.app`.
@MainActor
@Observable
final class IOSSimulatorLaunchModel {
    enum Phase: Equatable {
        case idle
        case listing
        case running(SimulatorInstallPhase)
        case succeeded(SimulatorLaunchResult)
        case failed(String)
    }

    private(set) var devices: [SimulatorDevice] = []
    private(set) var phase: Phase = .idle
    private(set) var listError: String?
    /// UDID captured when the current install started. UI state must show
    /// this device while the install is in flight, not a live re-read.
    private(set) var activeInstallUDID: String?

    private let service: SimulatorService
    private var generation = 0
    @ObservationIgnored private var listTask: Task<Void, Never>?
    @ObservationIgnored private var installTask: Task<Void, Never>?

    var isListing: Bool {
        if case .listing = phase { return true }
        return false
    }

    var isInstalling: Bool {
        if case .running = phase { return true }
        return false
    }

    var canCancelWait: Bool { isInstalling }

    var statusText: String? {
        switch phase {
        case .idle:
            return nil
        case .listing:
            return "Listing Simulators…"
        case .running(let step):
            return step.title
        case .succeeded(let result):
            return "Launched \(result.bundleIdentifier) on \(result.deviceName)."
        case .failed(let message):
            return message
        }
    }

    var errorMessage: String? {
        if case .failed(let message) = phase { return message }
        return listError
    }

    init(service: SimulatorService) {
        self.service = service
    }

    convenience init(processRunner: any ProcessRunning = SystemProcessRunner()) {
        self.init(service: SimulatorService(processRunner: processRunner))
    }

    func affectedDevice(udid: String?) -> SimulatorDevice? {
        guard let udid else { return nil }
        return devices.first { $0.udid == udid }
    }

    func affectedDeviceSummary(udid: String?) -> String {
        guard let udid, let trimmed = IOSProjectProfile.nilIfEmpty(udid) else {
            return "Choose a Simulator before installing. Console will not use whichever device happens to be booted."
        }
        if let device = affectedDevice(udid: trimmed) {
            let availability = device.isAvailable ? device.state.title : "unavailable runtime"
            return "Will install on \(device.displayName) (\(trimmed)). State: \(availability)."
        }
        return "Will install on \(trimmed). This Simulator is not in the current device list — Console will not fall back to a booted device."
    }

    func canInstall(job: IOSBuildJob?, udid: String?) -> Bool {
        guard !isInstalling else { return false }
        guard IOSProjectProfile.nilIfEmpty(udid) != nil else { return false }
        return job?.state == .succeeded
    }

    func refreshDevices() {
        generation += 1
        let current = generation
        listTask?.cancel()
        if !isInstalling {
            phase = .listing
        }
        listError = nil
        listTask = Task { [weak self] in
            await self?.performList(generation: current)
        }
    }

    func refreshAndWait() async {
        generation += 1
        let current = generation
        listTask?.cancel()
        if !isInstalling {
            phase = .listing
        }
        listError = nil
        await performList(generation: current)
    }

    func selectSimulator(_ udid: String?, workspaceID: UUID, store: IOSProjectProfileStore) {
        var profile = store.profileOrEmpty(for: workspaceID)
        profile.simulatorUDID = udid
        store.save(profile)
    }

    func installAndLaunch(job: IOSBuildJob?, udid: String?) {
        guard !isInstalling else { return }
        guard let job else {
            phase = .failed("Select a successful build before installing.")
            return
        }
        guard let udid = IOSProjectProfile.nilIfEmpty(udid) else {
            phase = .failed(SimulatorServiceError.missingSimulator.localizedDescription)
            return
        }
        if job.state != .succeeded {
            phase = .failed(SimulatorServiceError.failedBuild(job.state).localizedDescription)
            return
        }

        installTask?.cancel()
        listError = nil
        phase = .running(.resolvingProduct)
        activeInstallUDID = udid
        let service = self.service
        installTask = Task { [weak self] in
            await self?.performInstall(job: job, udid: udid, service: service)
        }
    }

    func installAndWait(job: IOSBuildJob?, udid: String?) async {
        guard !isInstalling else { return }
        guard let job else {
            phase = .failed("Select a successful build before installing.")
            return
        }
        guard let udid = IOSProjectProfile.nilIfEmpty(udid) else {
            phase = .failed(SimulatorServiceError.missingSimulator.localizedDescription)
            return
        }
        if job.state != .succeeded {
            phase = .failed(SimulatorServiceError.failedBuild(job.state).localizedDescription)
            return
        }
        installTask?.cancel()
        listError = nil
        phase = .running(.resolvingProduct)
        activeInstallUDID = udid
        await performInstall(job: job, udid: udid, service: service)
    }

    func cancelWaiting() {
        guard isInstalling else { return }
        activeInstallUDID = nil
        installTask?.cancel()
    }

    func openSimulator(udid: String?) {
        // An Open failure must not rewrite the phase of an in-flight install.
        guard !isInstalling else { return }
        guard let udid = IOSProjectProfile.nilIfEmpty(udid) else {
            phase = .failed(SimulatorServiceError.missingSimulator.localizedDescription)
            return
        }
        let service = self.service
        Task { [weak self] in
            do {
                try await service.openSimulator(udid: udid)
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        generation += 1
        listTask?.cancel()
        installTask?.cancel()
        listTask = nil
        installTask = nil
        activeInstallUDID = nil
        if isListing || isInstalling {
            phase = .idle
        }
    }

    private func performInstall(job: IOSBuildJob, udid: String, service: SimulatorService) async {
        defer { activeInstallUDID = nil }
        do {
            let result = try await service.installAndLaunch(job: job, udid: udid) { [weak self] step in
                Task { @MainActor in
                    guard let self, self.isInstalling else { return }
                    self.phase = .running(step)
                }
            }
            guard !Task.isCancelled else {
                phase = .failed(SimulatorServiceError.cancelled.localizedDescription)
                return
            }
            phase = .succeeded(result)
        } catch is CancellationError {
            phase = .failed(SimulatorServiceError.cancelled.localizedDescription)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func performList(generation: Int) async {
        do {
            let devices = try await service.listDevices()
            guard self.generation == generation, !Task.isCancelled else { return }
            self.devices = devices
            listError = nil
            if case .listing = phase {
                phase = .idle
            }
        } catch is CancellationError {
            return
        } catch {
            guard self.generation == generation else { return }
            listError = error.localizedDescription
            if case .listing = phase {
                phase = .idle
            }
        }
    }
}
