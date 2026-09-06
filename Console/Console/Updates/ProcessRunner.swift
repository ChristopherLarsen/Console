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

    var errorDescription: String? {
        switch self {
        case .executableMissing(let path):
            return "Executable was not found at \(path)."
        case .launchFailed(let message):
            return "Could not start process: \(message)"
        }
    }
}

/// Abstraction over spawning external processes so tests never run real git.
protocol ProcessRunning: Sendable {
    func run(executablePath: String,
             arguments: [String],
             workingDirectory: String?) async throws -> ProcessResult
}

/// Runs a process and waits for it to finish off the main actor.
/// stdout and stderr are drained from launch until EOF so a child that fills a
/// pipe cannot deadlock. Retained output is bounded; overflow is truncated and
/// reported. Task cancellation terminates the owned child (Stop, deadlines, and
/// force-kill are reserved for review item 06).
struct SystemProcessRunner: ProcessRunning {

    nonisolated static let defaultMaxOutputBytesPerStream = 1_048_576

    private let maxOutputBytesPerStream: Int

    nonisolated init(maxOutputBytesPerStream: Int = SystemProcessRunner.defaultMaxOutputBytesPerStream) {
        self.maxOutputBytesPerStream = maxOutputBytesPerStream
    }

    func run(executablePath: String,
             arguments: [String],
             workingDirectory: String?) async throws -> ProcessResult {
        let invocation = ProcessInvocation(
            executablePath: executablePath,
            arguments: arguments,
            workingDirectory: workingDirectory,
            maxOutputBytesPerStream: maxOutputBytesPerStream
        )
        return try await withTaskCancellationHandler {
            try await invocation.startAndWait()
        } onCancel: {
            invocation.terminate()
        }
    }
}

/// Owns exactly one child process and both pipes for a single invocation.
nonisolated final class ProcessInvocation: @unchecked Sendable {

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
    private var continuation: CheckedContinuation<ProcessResult, Error>?

    init(
        executablePath: String,
        arguments: [String],
        workingDirectory: String?,
        maxOutputBytesPerStream: Int
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.stdoutBuffer = OutputBuffer(limit: maxOutputBytesPerStream)
        self.stderrBuffer = OutputBuffer(limit: maxOutputBytesPerStream)
    }

    func terminate() {
        lock.lock()
        let running = process
        lock.unlock()
        if running?.isRunning == true {
            running?.terminate()
        }
    }

    func startAndWait() async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
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

    private func launch() throws {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw ProcessRunError.executableMissing(executablePath)
        }

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
        self.stdoutHandle = stdoutHandle
        self.stderrHandle = stderrHandle
        self.process = process
        lock.unlock()

        // Read on the FileHandle callback queues so both pipes drain concurrently
        // from launch. Hopping the read itself onto a serial queue deadlocks a
        // child that fills stdout and stderr at the same time.
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
            try process.run()
        } catch {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            process.terminationHandler = nil
            throw ProcessRunError.launchFailed(error.localizedDescription)
        }
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

