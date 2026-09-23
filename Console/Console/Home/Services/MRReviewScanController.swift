import Foundation
import Observation

/// Memory-only AI results. A failed or cancelled scan never replaces a successful snapshot.
@MainActor
@Observable
final class MRReviewScanController {
    static let shared = MRReviewScanController()
    typealias Performer = @MainActor (ClaudeOperationInvocation) async throws -> ClaudeOperationOutput

    private(set) var items: [MergeRequestSummary] = []
    private(set) var authoredItems: [AuthoredMRAttention] = []
    private(set) var authoredLastSuccessfulUpdate: Date?
    private(set) var authoredMessage: String?
    var discussionItems: [AuthoredMRAttention] { authoredItems.filter(\.hasDiscussions) }
    /// Pending notifications, rebuilt by each successful authored-MR scan.
    private(set) var approvedItems: [AuthoredMRAttention] = []
    private(set) var isScanning = false
    private(set) var lastSuccessfulUpdate: Date?
    private(set) var message: String?
    var manualError: String?
    private var performer: Performer?
    private let defaults: UserDefaults
    private let urlProvider: @MainActor () -> String
    private let executableProvider: () -> String?
    private let now: () -> Date
    private var resultScope: String?
    private var resultUsername: String?
    private var observedSettingsSignature = ""

    init(defaults: UserDefaults = .standard,
         urlProvider: @escaping @MainActor () -> String = { GitLabConfiguration.effectiveReviewsURLString() },
         executableProvider: @escaping () -> String? = { GLabExecutable.resolve() },
         now: @escaping () -> Date = Date.init,
         performer: Performer? = nil) {
        self.defaults = defaults
        self.urlProvider = urlProvider
        self.executableProvider = executableProvider
        self.now = now
        self.performer = performer
        observedSettingsSignature = settingsSignature
    }

    func configure(performer: @escaping Performer) { self.performer = performer }

    func dequeueApprovedNotification() -> AuthoredMRAttention? {
        guard !approvedItems.isEmpty else { return nil }
        return approvedItems.removeFirst()
    }

    /// Consumes the first unresolved-discussions notification until the next
    /// successful authored scan repopulates it.
    func dequeueDiscussionNotification() -> AuthoredMRAttention? {
        guard let index = authoredItems.firstIndex(where: \.hasDiscussions) else { return nil }
        return authoredItems.remove(at: index)
    }

    @discardableResult
    func checkGLabAvailability(manual: Bool) -> Bool {
        guard executableProvider() != nil else {
            authoredMessage = "glab is unavailable. Authored MR notifications may be out of date."
            message = "glab is not installed. Install it with brew install glab, then run glab auth login for your GitLab host."
            if manual { manualError = message }
            return false
        }
        return true
    }

    var settingsSignature: String {
        "\(urlProvider())|\(defaults.string(forKey: AppSettings.mrScanModelKey) ?? "")|\(MRReviewTriagePrompt.configuredText(defaults))"
    }

    var status: HomeSourceStatus {
        let check: HomeSourceStatus.Check
        if MRReviewTriagePrompt.configuredURL(urlProvider()) == nil { check = .unconfigured }
        else if isScanning { check = .pending }
        else if message != nil { check = lastSuccessfulUpdate == nil ? .failed : .stale }
        else { check = lastSuccessfulUpdate == nil ? .pending : .current }
        return HomeSourceStatus(check: check, lastSuccessfulExtraction: lastSuccessfulUpdate, failureReason: message)
    }

    func settingsChanged() {
        guard observedSettingsSignature != settingsSignature else { return }
        observedSettingsSignature = settingsSignature
        if let resultScope, resultScope != urlProvider() {
            items = []
            authoredItems = []
            approvedItems = []
            authoredLastSuccessfulUpdate = nil
            authoredMessage = nil
            lastSuccessfulUpdate = nil
            self.resultScope = nil
            resultUsername = nil
            message = nil
        } else if lastSuccessfulUpdate != nil {
            authoredMessage = "Scan settings changed. Refresh to update MR notifications."
            message = "Review settings changed. Refresh to update the cards."
        }
    }

    func scan(trigger: MRReviewScanTrigger) async -> MRReviewScanOutcome {
        guard !isScanning else { return .alreadyRefreshing }
        // Check before URL validation so a manual click always explains a missing installation.
        guard checkGLabAvailability(manual: trigger == .manual), let executable = executableProvider() else { return .failed }
        guard let url = MRReviewTriagePrompt.configuredURL(urlProvider()) else { return .unconfigured }
        guard let performer else {
            authoredMessage = "Scan unavailable. Check Claude access in Settings."
            message = "Review scan unavailable. Check Claude access in Settings, then refresh."
            return .failed
        }
        let signature = settingsSignature
        isScanning = true
        message = nil
        manualError = nil
        defer { isScanning = false }
        var authoredUpdated = false
        do {
            let invocation = try MRReviewTriagePrompt.invocation(url: url, executable: executable, defaults: defaults)
            let output = try await performer(invocation)
            try Task.checkCancellation()
            guard settingsSignature == signature else { return .cancelled }
            // A successful identity lookup may expose an account switch even when one
            // collection is incomplete. Never retain the previous account's badges/cards.
            if output.correlationID == invocation.correlationID,
               let text = output.resultText, text.utf8.count <= 4_000_000,
               let envelope = try? JSONDecoder().decode(MRReviewTriageResult.self, from: Data(text.utf8)) {
                let username = envelope.currentUsername.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !username.isEmpty {
                    if let previous = resultUsername, previous != username {
                        items = []
                        lastSuccessfulUpdate = nil
                        authoredItems = []
                        approvedItems = []
                        authoredLastSuccessfulUpdate = nil
                    }
                    resultUsername = username
                }
            }
            do {
                authoredItems = try AuthoredMRAttention.decode(output, invocation: invocation, scope: url)
                approvedItems = authoredItems.filter(\.isApproved)
                authoredLastSuccessfulUpdate = now()
                authoredMessage = nil
                authoredUpdated = true
                resultScope = urlProvider()
            } catch {
                authoredMessage = "Authored MR scan incomplete. Showing the last successful result."
            }
            let fresh = try MRReviewTriagePrompt.decode(output, invocation: invocation, scope: url)
            items = fresh
            lastSuccessfulUpdate = now()
            resultScope = urlProvider()
            return .refreshed(fresh.count)
        } catch {
            guard settingsSignature == signature else { return .cancelled }
            if Task.isCancelled {
                authoredMessage = "Scan cancelled. Authored MR notifications may be out of date."
                message = "Review scan cancelled. Refresh to retry."
                return .cancelled
            }
            // Provider errors can contain MR content; show fixed recovery text only.
            message = "Review scan failed or was incomplete. Check glab authentication, GitLab connectivity and Claude access, then refresh."
            if !authoredUpdated {
                authoredMessage = "Authored MR scan failed or was incomplete. Refresh to retry."
            }
            return .failed
        }
    }
}

enum GLabExecutable {
    /// GUI launches do not reliably inherit Homebrew's PATH. Never execute a shell to probe.
    nonisolated static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let paths = ["/opt/homebrew/bin", "/usr/local/bin"]
            + (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return paths.filter { $0.hasPrefix("/") }.map { $0 + "/glab" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
