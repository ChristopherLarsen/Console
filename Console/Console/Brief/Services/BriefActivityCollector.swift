import Foundation

/// Abstraction over yesterday-activity collection so tests inject synthetic
/// data instead of running git.
protocol BriefActivityCollecting: Sendable {
    func collectActivities(workspacePaths: [String],
                           day: Date,
                           calendar: Calendar) async -> [CommitActivity]
}

/// Collects the previous day's commit subjects across the registered session
/// workspaces. Local-only: reads each repository's own history through the
/// system git binary; never touches JIRA/GitLab web content or the network.
struct BriefActivityCollector: BriefActivityCollecting {
    private let processRunner: ProcessRunning
    private let gitExecutablePath: String

    init(processRunner: ProcessRunning = SystemProcessRunner(),
         gitExecutablePath: String = "/usr/bin/git") {
        self.processRunner = processRunner
        self.gitExecutablePath = gitExecutablePath
    }

    /// Commit activities across `workspacePaths` whose committer date falls
    /// within `day` (local calendar). Unreadable paths and non-repositories
    /// are skipped silently.
    func collectActivities(workspacePaths: [String],
                           day: Date,
                           calendar: Calendar = .current) async -> [CommitActivity] {
        let dayStart = calendar.startOfDay(for: day)
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        let formatter = ISO8601DateFormatter()
        var activities: [CommitActivity] = []

        for path in workspacePaths {
            let repositoryName = URL(fileURLWithPath: path).lastPathComponent
            let result = try? await processRunner.run(
                executablePath: gitExecutablePath,
                arguments: [
                    "-C", path, "log", "--no-merges",
                    "--since=\(formatter.string(from: dayStart))",
                    "--until=\(formatter.string(from: nextDay))",
                    "--pretty=format:\(BriefComposer.gitLogFormat)"
                ],
                workingDirectory: nil
            )
            guard let result, result.succeeded else { continue }
            activities.append(
                contentsOf: BriefComposer.parseGitLogOutput(result.standardOutput,
                                                            repositoryName: repositoryName)
            )
        }
        return activities
    }
}
