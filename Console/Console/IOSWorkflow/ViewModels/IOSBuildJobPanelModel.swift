import AppKit
import Foundation

/// Opens a local file or `.xcresult` with `NSWorkspace`. Tests inject a recorder
/// so unit tests never launch Xcode.
protocol IOSWorkspaceOpening {
    func open(_ url: URL)
}

struct SystemIOSWorkspaceOpener: IOSWorkspaceOpening {
    func open(_ url: URL) {
        if url.pathExtension.lowercased() == "xcresult",
           let xcode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") {
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: xcode,
                configuration: NSWorkspace.OpenConfiguration(),
                completionHandler: { _, _ in }
            )
            return
        }
        NSWorkspace.shared.open(url)
    }
}

/// Local clipboard only. Errors and source snippets are never forwarded to an
/// LLM or uploaded.
protocol IOSPasteboardWriting {
    func write(_ string: String)
}

struct SystemIOSPasteboardWriter: IOSPasteboardWriting {
    func write(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

/// Failed-test identifiers taken only from structured result issues — never
/// from log wording or the original selection.
nonisolated enum IOSFailedTestIdentifier {
    static func validated(_ raw: String?) -> String? {
        guard let trimmed = IOSProjectProfile.nilIfEmpty(raw) else { return nil }
        let candidate = identifier(fromTestURL: trimmed) ?? trimmed
        let cleaned = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let value = IOSProjectProfile.nilIfEmpty(cleaned) else { return nil }
        if value.contains("*") || value.contains("?") { return nil }
        if value.contains("://") { return nil }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts.count <= 8 else { return nil }
        guard parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        return parts.joined(separator: "/")
    }

    static func from(job: IOSBuildJob) -> [String] {
        guard let issues = job.resultSummary?.issues else { return [] }
        var seen = Set<String>()
        var ordered: [String] = []
        for issue in issues where issue.kind == .testFailure {
            guard let identifier = validated(issue.testIdentifier) else { continue }
            if seen.insert(identifier).inserted {
                ordered.append(identifier)
            }
        }
        return ordered
    }

    private static func identifier(fromTestURL raw: String) -> String? {
        guard let components = URLComponents(string: raw), components.scheme == "test" else {
            return nil
        }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty ? nil : path
    }
}

/// Pure presentation of one job for the compact iOS jobs panel.
nonisolated struct IOSBuildJobPresentation: Equatable, Sendable {
    var state: IOSBuildJobState
    var stateTitle: String
    var kindTitle: String
    var title: String
    var elapsedText: String
    var isInProgress: Bool
    var canStop: Bool
    var canOpenResult: Bool
    var canOpenSource: Bool
    var canCopyError: Bool
    var canRerunFailedTests: Bool
    var firstIssueText: String?
    var diagnosticText: String?
    var output: String
    var outputTruncated: Bool
    var resultURL: URL?
    var sourceURL: URL?
    var errorCopyText: String?
    var failedTestIdentifiers: [String]

    static func make(
        job: IOSBuildJob,
        now: Date,
        bundleExists: (URL) -> Bool
    ) -> IOSBuildJobPresentation {
        let firstIssue = job.resultSummary?.issues.first
        let sourceURL = job.resultSummary?.issues.compactMap(\.fileURL).first
        let resultURL = bundleExists(job.resultBundleURL) ? job.resultBundleURL : nil
        let failedIDs = IOSFailedTestIdentifier.from(job: job)
        let diagnostic = diagnosticText(for: job)
        let errorCopy = errorCopyText(job: job, firstIssue: firstIssue, diagnostic: diagnostic)
        return IOSBuildJobPresentation(
            state: job.state,
            stateTitle: stateTitle(job.state),
            kindTitle: kindTitle(job.kind),
            title: title(for: job),
            elapsedText: elapsedText(for: job, now: now),
            isInProgress: !job.state.isTerminal,
            canStop: !job.state.isTerminal,
            canOpenResult: resultURL != nil,
            canOpenSource: sourceURL != nil,
            canCopyError: errorCopy != nil,
            canRerunFailedTests: !failedIDs.isEmpty,
            firstIssueText: firstIssueText(firstIssue),
            diagnosticText: diagnostic,
            output: job.output,
            outputTruncated: job.outputTruncated,
            resultURL: resultURL,
            sourceURL: sourceURL,
            errorCopyText: errorCopy,
            failedTestIdentifiers: failedIDs
        )
    }

    static func stateTitle(_ state: IOSBuildJobState) -> String {
        state.title
    }

    static func kindTitle(_ kind: IOSBuildJobKind) -> String {
        switch kind {
        case .build: return "Build"
        case .runSelectedTests: return "Selected Tests"
        }
    }

    static func title(for job: IOSBuildJob) -> String {
        let scheme = job.profile.scheme ?? "No scheme"
        return "\(kindTitle(job.kind)) · \(scheme)"
    }

    static func elapsedText(for job: IOSBuildJob, now: Date) -> String {
        let start = job.startedAt ?? job.createdAt
        let end = job.finishedAt ?? now
        return formatElapsed(end.timeIntervalSince(start))
    }

    static func formatElapsed(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    static func firstIssueText(_ issue: IOSResultIssue?) -> String? {
        guard let issue else { return nil }
        var parts: [String] = []
        if let fileURL = issue.fileURL {
            let name = fileURL.lastPathComponent
            if let line = issue.line {
                parts.append("\(name):\(line)")
            } else {
                parts.append(name)
            }
        } else if let identifier = IOSFailedTestIdentifier.validated(issue.testIdentifier) {
            parts.append(identifier)
        }
        let message = issue.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty {
            parts.append(message)
        }
        let text = parts.joined(separator: "  ")
        guard !text.isEmpty else { return nil }
        if text.count > 240 {
            return String(text.prefix(237)) + "…"
        }
        return text
    }

    static func diagnosticText(for job: IOSBuildJob) -> String? {
        guard let summary = job.resultSummary else { return nil }
        switch summary.parseStatus {
        case .parsed:
            return nil
        case .missingBundle, .incompleteBundle, .corruptBundle, .schemaMismatch, .toolFailed:
            return IOSProjectProfile.nilIfEmpty(summary.diagnosticMessage)
        }
    }

    static func errorCopyText(
        job: IOSBuildJob,
        firstIssue: IOSResultIssue?,
        diagnostic: String?
    ) -> String? {
        if let issue = firstIssue {
            let message = issue.message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty { return message }
        }
        if let errorMessage = IOSProjectProfile.nilIfEmpty(job.errorMessage) {
            return errorMessage
        }
        return IOSProjectProfile.nilIfEmpty(diagnostic)
    }
}

/// Compact iOS job panel state: selection, local open/copy, and coordinator
/// actions. Job output stays on disk; nothing here uploads a bundle or sends
/// errors to an LLM.
@MainActor
@Observable
final class IOSBuildJobPanelModel {
    var selectedJobID: UUID?
    var selectedWorkspaceID: UUID?
    var isOutputExpanded = false
    var actionMessage: String?

    @ObservationIgnored let opener: any IOSWorkspaceOpening
    @ObservationIgnored let pasteboard: any IOSPasteboardWriting
    @ObservationIgnored let bundleExists: (URL) -> Bool
    @ObservationIgnored var now: () -> Date

    init(
        opener: (any IOSWorkspaceOpening)? = nil,
        pasteboard: (any IOSPasteboardWriting)? = nil,
        bundleExists: ((URL) -> Bool)? = nil,
        now: (() -> Date)? = nil
    ) {
        self.opener = opener ?? SystemIOSWorkspaceOpener()
        self.pasteboard = pasteboard ?? SystemIOSPasteboardWriter()
        self.bundleExists = bundleExists ?? { url in
            FileManager.default.fileExists(atPath: url.path)
        }
        self.now = now ?? { Date() }
    }

    func presentation(for job: IOSBuildJob, at date: Date? = nil) -> IOSBuildJobPresentation {
        IOSBuildJobPresentation.make(job: job, now: date ?? now(), bundleExists: bundleExists)
    }

    func selectedJob(from jobs: [IOSBuildJob]) -> IOSBuildJob? {
        if let selectedJobID, let match = jobs.first(where: { $0.id == selectedJobID }) {
            return match
        }
        return jobs.last
    }

    func selectLatestIfNeeded(from jobs: [IOSBuildJob]) {
        if let selectedJobID, jobs.contains(where: { $0.id == selectedJobID }) {
            return
        }
        selectedJobID = jobs.last?.id
    }

    func resolveWorkspaceID(from store: SessionWorkspaceStore) -> UUID? {
        if let selectedWorkspaceID, store.workspace(withID: selectedWorkspaceID) != nil {
            return selectedWorkspaceID
        }
        return store.defaultWorkspaceID ?? store.workspaces.first?.id
    }

    func submitBuild(coordinator: IOSBuildCoordinator, profile: IOSProjectProfile) {
        do {
            let id = try coordinator.submitBuild(profile: profile)
            selectedJobID = id
            actionMessage = nil
        } catch {
            actionMessage = error.localizedDescription
        }
    }

    func submitSelectedTests(coordinator: IOSBuildCoordinator, profile: IOSProjectProfile) {
        do {
            let id = try coordinator.submitSelectedTests(profile: profile)
            selectedJobID = id
            actionMessage = nil
        } catch {
            actionMessage = error.localizedDescription
        }
    }

    func stop(coordinator: IOSBuildCoordinator, jobs: [IOSBuildJob]) {
        guard let job = selectedJob(from: jobs), !job.state.isTerminal else { return }
        coordinator.cancel(job.id)
        actionMessage = nil
    }

    func openResult(job: IOSBuildJob) {
        let presentation = presentation(for: job)
        guard let url = presentation.resultURL else { return }
        opener.open(url)
        actionMessage = nil
    }

    func openSource(job: IOSBuildJob) {
        let presentation = presentation(for: job)
        guard let url = presentation.sourceURL else {
            if let resultURL = presentation.resultURL {
                opener.open(resultURL)
            }
            return
        }
        opener.open(url)
        actionMessage = nil
    }

    func copyError(job: IOSBuildJob) {
        let presentation = presentation(for: job)
        guard let text = presentation.errorCopyText else { return }
        pasteboard.write(text)
        actionMessage = nil
    }

    /// Re-runs only validated failed-test identifiers from the selected job's
    /// structured result records. Does not reuse the original test plan.
    func rerunFailedTests(coordinator: IOSBuildCoordinator, job: IOSBuildJob) {
        let identifiers = IOSFailedTestIdentifier.from(job: job)
        guard !identifiers.isEmpty else {
            actionMessage = "No failed tests to rerun."
            return
        }
        do {
            let id = try coordinator.submitSelectedTests(
                profile: job.profile,
                identifiers: identifiers
            )
            selectedJobID = id
            actionMessage = nil
        } catch {
            actionMessage = error.localizedDescription
        }
    }
}
