import Foundation

/// A checked-out source tree ready for a manual Release build in Xcode.
nonisolated struct PreparedSource: Equatable, Sendable {
    let directoryPath: String
    let xcodeProjectPath: String?
}

// MARK: - Errors

enum SourceCheckoutError: LocalizedError, Equatable {
    case invalidTag(String)
    case executableMissing(String)
    case launchFailed(String)
    case commandFailed(description: String, exitCode: Int32, stderr: String)
    case destinationExists(String)
    case missingXcodeProject

    var errorDescription: String? {
        switch self {
        case .invalidTag(let tag):
            return "\"\(tag)\" is not a valid release tag."
        case .executableMissing(let path):
            return "Git was not found at \(path). Install the Xcode Command Line Tools and try again."
        case .launchFailed(let message):
            return "Could not start git: \(message)"
        case .commandFailed(let description, let exitCode, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "\(description) failed (exit code \(exitCode))."
                : "\(description) failed (exit code \(exitCode)): \(detail)"
        case .destinationExists(let path):
            return "The folder \(path) already exists but does not contain a valid checkout of this release. Remove it and try again."
        case .missingXcodeProject:
            return "The downloaded source does not contain Console/Console.xcodeproj."
        }
    }
}

// MARK: - Service

protocol SourceCheckouting: Sendable {
    func prepare(tag: String) async throws -> PreparedSource
}

/// Clones the Console repository at an exact release tag into
/// `~/Developer/ConsoleUpdates/Console-vX.Y.Z` using `/usr/bin/git`.
///
/// Arguments are always passed as argv arrays — never shell-interpolated.
/// It never builds or installs anything and never touches the running app.
struct SourceCheckoutService: SourceCheckouting {

    nonisolated static let gitExecutablePath = "/usr/bin/git"
    nonisolated static let defaultRepositoryURL = "https://github.com/ChristopherLarsen/Console.git"
    nonisolated static let defaultDestinationRoot = NSString(string: "~/Developer/ConsoleUpdates").expandingTildeInPath

    let repositoryURL: String
    let destinationRoot: String
    let processRunner: any ProcessRunning

    nonisolated init(repositoryURL: String = SourceCheckoutService.defaultRepositoryURL,
                     destinationRoot: String = SourceCheckoutService.defaultDestinationRoot,
                     processRunner: any ProcessRunning = SystemProcessRunner()) {
        self.repositoryURL = repositoryURL
        self.destinationRoot = destinationRoot
        self.processRunner = processRunner
    }

    /// Directory that will hold the checkout for `tag`, e.g.
    /// `~/Developer/ConsoleUpdates/Console-v1.2.3`.
    nonisolated func destinationPath(for tag: String) -> String? {
        guard SemanticVersion.parse(tag) != nil else { return nil }
        return destinationRoot + "/Console-\(tag)"
    }

    func prepare(tag: String) async throws -> PreparedSource {
        // Validate before it ever reaches a filesystem path or argv slot.
        guard let destination = destinationPath(for: tag) else {
            throw SourceCheckoutError.invalidTag(tag)
        }

        let fm = FileManager.default
        try fm.createDirectory(atPath: destinationRoot, withIntermediateDirectories: true)

        if fm.fileExists(atPath: destination) {
            // Idempotent re-prepare: accept only a real checkout already
            // holding the tag. The tag ref existing is not enough — HEAD
            // must resolve to the same commit.
            let result = try await runGit(
                ["-C", destination, "rev-parse", "--verify", "--quiet", "HEAD", "refs/tags/\(tag)^{commit}"],
                description: "Verifying existing checkout",
                workingDirectory: destination
            )
            let commits = result.standardOutput
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard result.succeeded, commits.count == 2, commits[0] == commits[1],
                  let projectPath = Self.locateXcodeProject(in: destination) else {
                throw SourceCheckoutError.destinationExists(destination)
            }
            return PreparedSource(directoryPath: destination, xcodeProjectPath: projectPath)
        }

        // Clone into a temporary sibling, then rename atomically so a failed or
        // cancelled clone never leaves a half-written destination behind.
        let stagingPath = destination + ".staging-\(UUID().uuidString)"
        defer {
            try? fm.removeItem(atPath: stagingPath)
        }

        let clone = try await runGit(
            ["clone", "--depth", "1", "--single-branch", "--branch", tag, repositoryURL, stagingPath],
            description: "Downloading source for \(tag)",
            workingDirectory: destinationRoot
        )
        guard clone.succeeded else {
            throw SourceCheckoutError.commandFailed(
                description: "Downloading source for \(tag)",
                exitCode: clone.exitCode,
                stderr: clone.standardError
            )
        }

        guard Self.locateXcodeProject(in: stagingPath) != nil else {
            throw SourceCheckoutError.missingXcodeProject
        }

        do {
            try fm.moveItem(atPath: stagingPath, toPath: destination)
        } catch {
            throw SourceCheckoutError.commandFailed(
                description: "Moving checkout into place",
                exitCode: -1,
                stderr: error.localizedDescription
            )
        }

        return PreparedSource(
            directoryPath: destination,
            xcodeProjectPath: destination + "/" + Self.xcodeProjectRelativePath
        )
    }

    // MARK: - Git plumbing

    @discardableResult
    private func runGit(_ arguments: [String],
                        description: String,
                        workingDirectory: String?) async throws -> ProcessResult {
        do {
            return try await processRunner.run(
                executablePath: Self.gitExecutablePath,
                arguments: arguments,
                workingDirectory: workingDirectory
            )
        } catch let error as SourceCheckoutError {
            throw error
        } catch let error as ProcessRunError {
            switch error {
            case .executableMissing(let path):
                throw SourceCheckoutError.executableMissing(path)
            case .launchFailed(let message):
                throw SourceCheckoutError.launchFailed(message)
            case .cancelled:
                throw CancellationError()
            case .timedOut:
                throw SourceCheckoutError.launchFailed(error.localizedDescription)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SourceCheckoutError.launchFailed(error.localizedDescription)
        }
    }

    /// The Xcode project lives at `Console/Console.xcodeproj` in this repository.
    static let xcodeProjectRelativePath = "Console/Console.xcodeproj"

    /// Returns the path to `Console/Console.xcodeproj` if that directory exists.
    static func locateXcodeProject(in directoryPath: String) -> String? {
        let path = directoryPath + "/" + xcodeProjectRelativePath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return path
    }
}
