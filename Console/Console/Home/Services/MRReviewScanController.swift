import Foundation
import Observation

/// Memory-only AI results. A failed or cancelled scan never replaces a successful snapshot.
@MainActor
@Observable
final class MRReviewScanController {
    static let shared = MRReviewScanController()
    typealias Performer = @MainActor (ClaudeOperationInvocation) async throws -> ClaudeOperationOutput

    private(set) var items: [MergeRequestSummary] = []
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

    @discardableResult
    func checkGLabAvailability(manual: Bool) -> Bool {
        guard executableProvider() != nil else {
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
            lastSuccessfulUpdate = nil
            self.resultScope = nil
            message = nil
        } else if lastSuccessfulUpdate != nil {
            message = "Review settings changed. Refresh to update the cards."
        }
    }

    func scan(trigger: MRReviewScanTrigger) async -> MRReviewScanOutcome {
        guard !isScanning else { return .alreadyRefreshing }
        // Check before URL validation so a manual click always explains a missing installation.
        guard checkGLabAvailability(manual: trigger == .manual), let executable = executableProvider() else { return .failed }
        guard let url = MRReviewTriagePrompt.configuredURL(urlProvider()) else { return .unconfigured }
        guard let performer else {
            message = "Review scan unavailable. Check Claude access in Settings, then refresh."
            return .failed
        }
        let signature = settingsSignature
        isScanning = true
        message = nil
        manualError = nil
        defer { isScanning = false }
        do {
            let invocation = try MRReviewTriagePrompt.invocation(url: url, executable: executable, defaults: defaults)
            let output = try await performer(invocation)
            try Task.checkCancellation()
            guard settingsSignature == signature else { return .cancelled }
            let fresh = try MRReviewTriagePrompt.decode(output, invocation: invocation, scope: url)
            items = fresh
            lastSuccessfulUpdate = now()
            resultScope = urlProvider()
            return .refreshed(fresh.count)
        } catch {
            guard settingsSignature == signature else { return .cancelled }
            if Task.isCancelled {
                message = "Review scan cancelled. Refresh to retry."
                return .cancelled
            }
            // Provider errors can contain MR content; show fixed recovery text only.
            message = "Review scan failed or was incomplete. Check glab authentication, GitLab connectivity and Claude access, then refresh."
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
