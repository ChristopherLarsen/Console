import Foundation

/// Serializes Console-owned iOS Build and Run Selected Tests jobs.
///
/// Constructs structured `xcodebuild` argv from an immutable
/// `IOSProjectProfile` snapshot (item 19) and runs it through `ProcessRunning`
/// (items 05–07). One job runs at a time; later submits stay `.queued`.
/// Result bundles are distinct paths recorded on the job; parsing them is a
/// later slice. Success is the exit code, never log wording.
@MainActor
@Observable
final class IOSBuildCoordinator {
    private(set) var jobs: [IOSBuildJob] = []

    private let processRunner: any ProcessRunning
    private let timeouts: IOSBuildTimeouts
    private let xcodebuildPath: String
    private let resultsDirectory: URL
    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    @ObservationIgnored private var pendingIDs: [UUID] = []
    @ObservationIgnored private var cancelledIDs: Set<UUID> = []
    @ObservationIgnored private var waiters: [UUID: [CheckedContinuation<IOSBuildJob, Never>]] = [:]
    @ObservationIgnored private var isProcessing = false
    @ObservationIgnored private var runningTask: Task<ProcessResult, Error>?
    @ObservationIgnored private var runningJobID: UUID?

    nonisolated static func defaultResultsDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("Console/IOSBuildJobs", isDirectory: true)
    }

    init(
        processRunner: any ProcessRunning,
        timeouts: IOSBuildTimeouts = .default,
        xcodebuildPath: String = IOSXcodebuildCommand.defaultXcodebuildPath,
        resultsDirectory: URL? = nil,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.processRunner = processRunner
        self.timeouts = timeouts
        self.xcodebuildPath = xcodebuildPath
        self.resultsDirectory = resultsDirectory ?? Self.defaultResultsDirectory(fileManager: fileManager)
        self.fileManager = fileManager
        self.now = { now() }
    }

    func job(id: UUID) -> IOSBuildJob? {
        jobs.first { $0.id == id }
    }

    /// Enqueue a `xcodebuild build` for the snapshotted profile.
    @discardableResult
    func submitBuild(profile: IOSProjectProfile) throws -> UUID {
        let snapshot = profile.normalized()
        try IOSXcodebuildCommand.validateBuild(snapshot)
        return enqueue(kind: .build, profile: snapshot, selection: nil)
    }

    /// Enqueue `xcodebuild test` with an explicit test plan and/or identifiers.
    /// Refuses to launch when neither is present, including when the profile
    /// has no saved test plan — a whole UI suite is never implied.
    @discardableResult
    func submitSelectedTests(
        profile: IOSProjectProfile,
        identifiers: [String] = [],
        testPlan: String? = nil
    ) throws -> UUID {
        let snapshot = profile.normalized()
        let selection = IOSTestSelection(identifiers: identifiers, testPlan: testPlan)
            .resolving(profile: snapshot)
        try IOSXcodebuildCommand.validateTest(snapshot, selection: selection)
        return enqueue(kind: .runSelectedTests, profile: snapshot, selection: selection)
    }

    func cancel(_ id: UUID) {
        guard let job = job(id: id), !job.state.isTerminal else { return }
        cancelledIDs.insert(id)
        if job.state == .queued {
            complete(id, state: .cancelled, errorMessage: "The job was cancelled.")
            return
        }
        runningTask?.cancel()
    }

    /// Suspends until the job is terminal. Returns immediately if it already is.
    func wait(for id: UUID) async -> IOSBuildJob {
        if let job = job(id: id), job.state.isTerminal {
            return job
        }
        return await withCheckedContinuation { continuation in
            waiters[id, default: []].append(continuation)
        }
    }

    // MARK: - Queue

    private func enqueue(
        kind: IOSBuildJobKind,
        profile: IOSProjectProfile,
        selection: IOSTestSelection?
    ) -> UUID {
        let id = UUID()
        let bundleURL = resultsDirectory.appendingPathComponent("\(id.uuidString).xcresult")
        let job = IOSBuildJob.queued(
            id: id,
            kind: kind,
            profile: profile,
            testSelection: selection,
            resultBundleURL: bundleURL,
            createdAt: now()
        )
        jobs.append(job)
        pendingIDs.append(id)
        startProcessingIfNeeded()
        return id
    }

    private func startProcessingIfNeeded() {
        guard !isProcessing else { return }
        isProcessing = true
        Task { await self.processQueue() }
    }

    private func processQueue() async {
        while true {
            if let id = popNextRunnable() {
                await execute(id)
                continue
            }
            isProcessing = false
            return
        }
    }

    private func popNextRunnable() -> UUID? {
        while !pendingIDs.isEmpty {
            let id = pendingIDs.removeFirst()
            guard let job = job(id: id), job.state == .queued else { continue }
            if cancelledIDs.contains(id) {
                complete(id, state: .cancelled, errorMessage: "The job was cancelled.")
                continue
            }
            return id
        }
        return nil
    }

    private func execute(_ id: UUID) async {
        guard var current = job(id: id), current.state == .queued else { return }
        if cancelledIDs.contains(id) {
            complete(id, state: .cancelled, errorMessage: "The job was cancelled.")
            return
        }

        current.state = .running
        current.startedAt = now()
        replace(current)

        let spec: ProcessLaunchSpec
        do {
            spec = try IOSXcodebuildCommand.makeLaunchSpec(
                kind: current.kind,
                profile: current.profile,
                selection: current.testSelection,
                resultBundleURL: current.resultBundleURL,
                timeouts: timeouts,
                xcodebuildPath: xcodebuildPath
            )
            try fileManager.createDirectory(at: resultsDirectory, withIntermediateDirectories: true)
        } catch {
            complete(id, state: .failed, errorMessage: error.localizedDescription)
            return
        }

        if cancelledIDs.contains(id) {
            complete(id, state: .cancelled, errorMessage: "The job was cancelled.")
            return
        }

        let payload = ShellPayload.structured(
            executable: spec.executablePath,
            arguments: spec.arguments,
            workingDirectory: spec.workingDirectory
        )
        let deadline = now().addingTimeInterval(timeouts.duration(for: current.kind))
        let runner = processRunner
        runningJobID = id
        let task = Task<ProcessResult, Error> {
            try Task.checkCancellation()
            return try await runner.run(payload, deadline: deadline)
        }
        runningTask = task
        if cancelledIDs.contains(id) {
            task.cancel()
        }

        do {
            let result = try await task.value
            runningTask = nil
            runningJobID = nil
            finish(id, result: result)
        } catch {
            runningTask = nil
            runningJobID = nil
            finish(id, error: error)
        }
    }

    private func finish(_ id: UUID, result: ProcessResult) {
        let state: IOSBuildJobState = result.exitCode == 0 ? .succeeded : .failed
        complete(id, state: state, result: result)
    }

    private func finish(_ id: UUID, error: Error) {
        if let processError = error as? ProcessRunError {
            switch processError {
            case .cancelled:
                complete(id, state: .cancelled, errorMessage: processError.localizedDescription)
            case .timedOut:
                complete(id, state: .timedOut, errorMessage: processError.localizedDescription)
            case .executableMissing, .launchFailed:
                complete(id, state: .failed, errorMessage: processError.localizedDescription)
            }
            return
        }
        if error is CancellationError {
            complete(id, state: .cancelled, errorMessage: ProcessRunError.cancelled.localizedDescription)
            return
        }
        complete(id, state: .failed, errorMessage: error.localizedDescription)
    }

    private func complete(
        _ id: UUID,
        state: IOSBuildJobState,
        result: ProcessResult? = nil,
        errorMessage: String? = nil
    ) {
        guard var job = job(id: id), !job.state.isTerminal else { return }
        job.state = state
        job.finishedAt = now()
        if let result {
            job.exitCode = result.exitCode
            job.standardOutput = result.formattedStandardOutput
            job.standardError = result.formattedStandardError
            job.outputTruncated = result.standardOutputTruncated || result.standardErrorTruncated
        }
        job.errorMessage = errorMessage
        replace(job)
        resumeWaiters(job)
    }

    private func replace(_ job: IOSBuildJob) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        }
    }

    private func resumeWaiters(_ job: IOSBuildJob) {
        let pending = waiters.removeValue(forKey: job.id) ?? []
        for continuation in pending {
            continuation.resume(returning: job)
        }
    }
}
