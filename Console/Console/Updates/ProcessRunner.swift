import Foundation

/// Result of one external process invocation.
struct ProcessResult: Sendable, Equatable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String

    var succeeded: Bool { exitCode == 0 }
}

/// Abstraction over spawning external processes so tests never run real git.
protocol ProcessRunning: Sendable {
    func run(executablePath: String,
             arguments: [String],
             workingDirectory: String?) async throws -> ProcessResult
}

/// Runs a process and waits for it to finish. Task cancellation terminates the
/// child process. Pipes are drained concurrently so long output cannot deadlock.
struct SystemProcessRunner: ProcessRunning {

    func run(executablePath: String,
             arguments: [String],
             workingDirectory: String?) async throws -> ProcessResult {
        let invocation = Invocation(executablePath: executablePath,
                                    arguments: arguments,
                                    workingDirectory: workingDirectory)
        return try await withTaskCancellationHandler {
            try await invocation.startAndWait()
        } onCancel: {
            invocation.terminate()
        }
    }

    /// Owns exactly one child process lifecycle.
    private final class Invocation: @unchecked Sendable {

        private let executablePath: String
        private let arguments: [String]
        private let workingDirectory: String?
        private var process: Process?
        private let lock = NSLock()

        init(executablePath: String, arguments: [String], workingDirectory: String?) {
            self.executablePath = executablePath
            self.arguments = arguments
            self.workingDirectory = workingDirectory
        }

        func terminate() {
            lock.lock()
            let running = process?.isRunning ?? false
            if running { process?.terminate() }
            lock.unlock()
        }

        func startAndWait() async throws -> ProcessResult {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let result = try self.executeBlocking()
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        private func executeBlocking() throws -> ProcessResult {
            guard FileManager.default.isExecutableFile(atPath: executablePath) else {
                throw SourceCheckoutError.executableMissing(executablePath)
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

            lock.lock()
            self.process = process
            lock.unlock()

            do {
                try process.run()
            } catch {
                throw SourceCheckoutError.launchFailed(error.localizedDescription)
            }

            // Drain both pipes concurrently; waitUntilExit blocks its own thread.
            let group = DispatchGroup()
            var stdoutData = Data()
            var stderrData = Data()

            group.enter()
            DispatchQueue.global().async { stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            group.enter()
            DispatchQueue.global().async { stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            group.enter()
            DispatchQueue.global().async { process.waitUntilExit(); group.leave() }
            group.wait()

            return ProcessResult(
                exitCode: process.terminationStatus,
                standardOutput: String(decoding: stdoutData, as: UTF8.self),
                standardError: String(decoding: stderrData, as: UTF8.self)
            )
        }
    }
}
