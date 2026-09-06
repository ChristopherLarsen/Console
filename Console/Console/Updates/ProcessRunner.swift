import Darwin
import Foundation

/// Result of one external process invocation.
struct ProcessResult: Sendable, Equatable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
    let standardOutputTruncated: Bool
    let standardErrorTruncated: Bool
    let standardOutputByteCount: Int
    let standardErrorByteCount: Int

    var succeeded: Bool { exitCode == 0 }

    init(
        exitCode: Int32,
        standardOutput: String,
        standardError: String,
        standardOutputTruncated: Bool = false,
        standardErrorTruncated: Bool = false,
        standardOutputByteCount: Int? = nil,
        standardErrorByteCount: Int? = nil
    ) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.standardOutputTruncated = standardOutputTruncated
        self.standardErrorTruncated = standardErrorTruncated
        self.standardOutputByteCount = standardOutputByteCount ?? standardOutput.utf8.count
        self.standardErrorByteCount = standardErrorByteCount ?? standardError.utf8.count
    }

    var formattedStandardOutput: String {
        Self.format(
            standardOutput,
            truncated: standardOutputTruncated,
            totalBytes: standardOutputByteCount,
            label: "stdout"
        )
    }

    var formattedStandardError: String {
        Self.format(
            standardError,
            truncated: standardErrorTruncated,
            totalBytes: standardErrorByteCount,
            label: "stderr"
        )
    }

    private static func format(
        _ text: String,
        truncated: Bool,
        totalBytes: Int,
        label: String
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard truncated else { return trimmed }
        let kept = text.utf8.count
        let notice = "[\(label) truncated after \(kept) bytes; \(totalBytes) bytes produced]"
        return trimmed.isEmpty ? notice : "\(trimmed)\n\(notice)"
    }
}

enum ProcessRunError: LocalizedError, Equatable {
    case executableMissing(String)
    case launchFailed(String)
    case cancelled
    case timedOut

    var errorDescription: String? {
        switch self {
        case .executableMissing(let path):
            return "Executable was not found at \(path)."
        case .launchFailed(let message):
            return "Could not start process: \(message)"
        case .cancelled:
            return "Process was cancelled."
        case .timedOut:
            return "Process timed out."
        }
    }
}

enum ProcessStopReason: Sendable, Equatable {
    case cancelled
    case timedOut

    var error: ProcessRunError {
        switch self {
        case .cancelled: return .cancelled
        case .timedOut: return .timedOut
        }
    }
}

/// Abstraction over spawning external processes so tests never run real git.
protocol ProcessRunning: Sendable {
    func run(executablePath: String,
             arguments: [String],
             workingDirectory: String?,
             deadline: Date?) async throws -> ProcessResult
}

extension ProcessRunning {
    func run(executablePath: String,
             arguments: [String],
             workingDirectory: String?) async throws -> ProcessResult {
        try await run(
            executablePath: executablePath,
            arguments: arguments,
            workingDirectory: workingDirectory,
            deadline: nil
        )
    }
}

/// Runs a process and waits for it to finish off the main actor.
/// stdout and stderr are drained from launch until EOF so a child that fills a
/// pipe cannot deadlock. Retained output is bounded; overflow is truncated and
/// reported. Task cancellation and an optional deadline both stop the owned
/// child with SIGTERM, then SIGKILL after ``ProcessInvocation/defaultForceStopGrace``.
struct SystemProcessRunner: ProcessRunning {

    nonisolated static let defaultMaxOutputBytesPerStream = 1_048_576

    private let maxOutputBytesPerStream: Int
    private let forceStopGrace: TimeInterval

    nonisolated init(
        maxOutputBytesPerStream: Int = SystemProcessRunner.defaultMaxOutputBytesPerStream,
        forceStopGrace: TimeInterval = ProcessInvocation.defaultForceStopGrace
    ) {
        self.maxOutputBytesPerStream = maxOutputBytesPerStream
        self.forceStopGrace = forceStopGrace
    }

    func run(executablePath: String,
             arguments: [String],
             workingDirectory: String?,
             deadline: Date?) async throws -> ProcessResult {
        let invocation = ProcessInvocation(
            executablePath: executablePath,
            arguments: arguments,
            workingDirectory: workingDirectory,
            maxOutputBytesPerStream: maxOutputBytesPerStream,
            forceStopGrace: forceStopGrace
        )
        return try await withTaskCancellationHandler {
            try await invocation.startAndWait(deadline: deadline)
        } onCancel: {
            invocation.requestStop(.cancelled)
        }
    }
}

/// Owns exactly one child process and both pipes for a single invocation.
nonisolated final class ProcessInvocation: @unchecked Sendable {

    /// Seconds to wait after SIGTERM before SIGKILL on the owned process tree.
    nonisolated static let defaultForceStopGrace: TimeInterval = 2

    private enum Stream {
        case stdout
        case stderr
    }

    private struct OutputBuffer {
        let limit: Int
        private(set) var retained = Data()
        private(set) var totalByteCount = 0
        private(set) var truncated = false

        mutating func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            totalByteCount += chunk.count
            if truncated { return }
            if retained.count >= limit {
                truncated = true
                return
            }
            let room = limit - retained.count
            if chunk.count <= room {
                retained.append(chunk)
            } else {
                if room > 0 {
                    retained.append(chunk.prefix(room))
                }
                truncated = true
            }
        }
    }

    private let executablePath: String
    private let arguments: [String]
    private let workingDirectory: String?
    private let forceStopGrace: TimeInterval
    private let lock = NSLock()

    private var process: Process?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var stdoutBuffer: OutputBuffer
    private var stderrBuffer: OutputBuffer
    private var stdoutEOF = false
    private var stderrEOF = false
    private var terminated = false
    private var didFinish = false
    private var launched = false
    private var stopReason: ProcessStopReason?
    private var rememberedPIDs = Set<pid_t>()
    private var deadlineWork: DispatchWorkItem?
    private var forceStopWork: DispatchWorkItem?
    private var continuation: CheckedContinuation<ProcessResult, Error>?

    init(
        executablePath: String,
        arguments: [String],
        workingDirectory: String?,
        maxOutputBytesPerStream: Int,
        forceStopGrace: TimeInterval = ProcessInvocation.defaultForceStopGrace
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.forceStopGrace = forceStopGrace
        self.stdoutBuffer = OutputBuffer(limit: maxOutputBytesPerStream)
        self.stderrBuffer = OutputBuffer(limit: maxOutputBytesPerStream)
    }

    func terminate() {
        requestStop(.cancelled)
    }

    func requestStop(_ reason: ProcessStopReason) {
        lock.lock()
        if stopReason == nil {
            stopReason = reason
        }
        let alreadyFinished = didFinish
        let alreadyLaunched = launched
        let pid = process?.processIdentifier ?? 0
        lock.unlock()

        guard !alreadyFinished else { return }
        guard alreadyLaunched, pid > 1 else { return }

        signalOwnedTree(root: pid, signal: SIGTERM)
        scheduleForceStop()
    }

    func startAndWait(deadline: Date? = nil) async throws -> ProcessResult {
        if Task.isCancelled {
            requestStop(.cancelled)
        }
        scheduleDeadline(deadline)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
                do {
                    try launch()
                } catch {
                    finish(.failure(error))
                }
            }
        }
    }

    private func scheduleDeadline(_ deadline: Date?) {
        guard let deadline else { return }
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 {
            requestStop(.timedOut)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.requestStop(.timedOut)
        }
        lock.lock()
        deadlineWork = work
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + remaining,
            execute: work
        )
    }

    private func scheduleForceStop() {
        lock.lock()
        if forceStopWork != nil || didFinish {
            lock.unlock()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.forceStopIfNeeded()
        }
        forceStopWork = work
        let grace = forceStopGrace
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + grace,
            execute: work
        )
    }

    private func forceStopIfNeeded() {
        lock.lock()
        if didFinish {
            lock.unlock()
            return
        }
        let pid = process?.processIdentifier ?? 0
        lock.unlock()
        guard pid > 1 else { return }
        signalOwnedTree(root: pid, signal: SIGKILL)
    }

    private func signalOwnedTree(root: pid_t, signal: Int32) {
        let extra: Set<pid_t> = {
            lock.lock()
            let remembered = rememberedPIDs
            lock.unlock()
            return remembered
        }()
        let signaled = OwnedProcessTree.signalOwned(root: root, signal: signal, extra: extra)
        lock.lock()
        rememberedPIDs.formUnion(signaled)
        lock.unlock()
    }

    private func throwIfStopped() throws {
        if Task.isCancelled {
            requestStop(.cancelled)
        }
        lock.lock()
        let reason = stopReason
        lock.unlock()
        if let reason {
            throw reason.error
        }
    }

    private func launch() throws {
        try throwIfStopped()

        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw ProcessRunError.executableMissing(executablePath)
        }

        try throwIfStopped()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }
        process.qualityOfService = .userInitiated

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        lock.lock()
        if let reason = stopReason {
            lock.unlock()
            throw reason.error
        }
        self.stdoutHandle = stdoutHandle
        self.stderrHandle = stderrHandle
        self.process = process
        lock.unlock()

        stdoutHandle.readabilityHandler = { [weak self] handle in
            self?.consume(handle, stream: .stdout)
        }
        stderrHandle.readabilityHandler = { [weak self] handle in
            self?.consume(handle, stream: .stderr)
        }
        process.terminationHandler = { [weak self] proc in
            self?.noteTerminated(proc)
        }

        do {
            try throwIfStopped()
            try process.run()
        } catch let error as ProcessRunError {
            clearLaunchHandlers(process, stdoutHandle: stdoutHandle, stderrHandle: stderrHandle)
            throw error
        } catch {
            clearLaunchHandlers(process, stdoutHandle: stdoutHandle, stderrHandle: stderrHandle)
            throw ProcessRunError.launchFailed(error.localizedDescription)
        }

        lock.lock()
        launched = true
        let pendingStop = stopReason
        lock.unlock()

        if let pendingStop {
            requestStop(pendingStop)
        }
    }

    private func clearLaunchHandlers(
        _ process: Process,
        stdoutHandle: FileHandle,
        stderrHandle: FileHandle
    ) {
        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        process.terminationHandler = nil
    }

    private func consume(_ handle: FileHandle, stream: Stream) {
        let chunk = handle.availableData
        if chunk.isEmpty {
            handle.readabilityHandler = nil
            noteEOF(stream)
            return
        }
        lock.lock()
        switch stream {
        case .stdout: stdoutBuffer.append(chunk)
        case .stderr: stderrBuffer.append(chunk)
        }
        lock.unlock()
    }

    private func noteEOF(_ stream: Stream) {
        lock.lock()
        switch stream {
        case .stdout: stdoutEOF = true
        case .stderr: stderrEOF = true
        }
        finishIfCompleteLocked()
    }

    private func noteTerminated(_ process: Process) {
        lock.lock()
        terminated = true
        self.process = process
        finishIfCompleteLocked()
    }

    /// Caller must hold `lock`. Unlocks before resuming the continuation.
    private func finishIfCompleteLocked() {
        guard terminated, stdoutEOF, stderrEOF else {
            lock.unlock()
            return
        }
        if let reason = stopReason {
            finishLocked(.failure(reason.error))
            return
        }
        let status = process?.terminationStatus ?? -1
        let result = ProcessResult(
            exitCode: status,
            standardOutput: String(decoding: stdoutBuffer.retained, as: UTF8.self),
            standardError: String(decoding: stderrBuffer.retained, as: UTF8.self),
            standardOutputTruncated: stdoutBuffer.truncated,
            standardErrorTruncated: stderrBuffer.truncated,
            standardOutputByteCount: stdoutBuffer.totalByteCount,
            standardErrorByteCount: stderrBuffer.totalByteCount
        )
        finishLocked(.success(result))
    }

    private func finish(_ result: Result<ProcessResult, Error>) {
        lock.lock()
        finishLocked(result)
    }

    /// Caller must hold `lock`.
    private func finishLocked(_ result: Result<ProcessResult, Error>) {
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        process?.terminationHandler = nil
        deadlineWork?.cancel()
        forceStopWork?.cancel()
        deadlineWork = nil
        forceStopWork = nil
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        switch result {
        case .success(let value):
            continuation?.resume(returning: value)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }
}

/// Signals only the owned child and processes currently descended from it.
/// Never signals pid 0/1, this process, or its parent (Xcode / test host).
enum OwnedProcessTree {
    @discardableResult
    static func signalOwned(root: pid_t, signal: Int32, extra: Set<pid_t> = []) -> Set<pid_t> {
        let selfPID = getpid()
        let parentPID = getppid()
        var targets = descendantIDs(of: root)
        if root > 1 {
            targets.insert(root)
        }
        targets.formUnion(extra)
        var signaled = Set<pid_t>()
        for pid in targets {
            guard pid > 1, pid != selfPID, pid != parentPID else { continue }
            _ = kill(pid, signal)
            signaled.insert(pid)
        }
        return signaled
    }

    static func isRunning(_ pid: pid_t) -> Bool {
        guard pid > 1 else { return false }
        return kill(pid, 0) == 0
    }

    static func descendantIDs(of root: pid_t) -> Set<pid_t> {
        guard root > 1 else { return [] }
        let parentByPID = processParents()
        var owned = Set<pid_t>()
        var stack = [root]
        while let current = stack.popLast() {
            for (pid, ppid) in parentByPID where ppid == current && pid != current && pid > 1 {
                if owned.insert(pid).inserted {
                    stack.append(pid)
                }
            }
        }
        return owned
    }

    private static func processParents() -> [pid_t: pid_t] {
        var map: [pid_t: pid_t] = [:]
        for pid in listAllPIDs() {
            if let ppid = parentPID(of: pid) {
                map[pid] = ppid
            }
        }
        return map
    }

    private static func listAllPIDs() -> [pid_t] {
        var capacity = 1024
        for _ in 0..<4 {
            var pids = [pid_t](repeating: 0, count: capacity)
            let bytes = proc_listpids(
                UInt32(PROC_ALL_PIDS),
                0,
                &pids,
                Int32(pids.count * MemoryLayout<pid_t>.size)
            )
            guard bytes > 0 else { return [] }
            let filled = Int(bytes) / MemoryLayout<pid_t>.size
            if filled < pids.count {
                return Array(pids.prefix(filled).filter { $0 > 0 })
            }
            capacity *= 2
        }
        return []
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard result == size else { return nil }
        return pid_t(info.pbi_ppid)
    }
}
