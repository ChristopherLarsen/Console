import Foundation

// MARK: - Result presentation (package D)

/// How Ticket Work classifies an inspected `.xcresult` for UI and evidence.
/// Maps 1:1 from ``IOSResultParseStatus`` plus an explicit "no summary" case.
/// Never invents success from missing or unreadable bundles.
nonisolated enum TicketWorkflowResultAvailability: String, Equatable, Sendable {
    case parsed
    case missingBundle
    case incompleteBundle
    case corruptBundle
    case schemaMismatch
    case toolFailed
    /// Job finished without an attached ``IOSResultSummary``.
    case unavailable

    init(parseStatus: IOSResultParseStatus) {
        switch parseStatus {
        case .parsed: self = .parsed
        case .missingBundle: self = .missingBundle
        case .incompleteBundle: self = .incompleteBundle
        case .corruptBundle: self = .corruptBundle
        case .schemaMismatch: self = .schemaMismatch
        case .toolFailed: self = .toolFailed
        }
    }

    /// True only when structured xcresult records were successfully parsed.
    var hasStructuredRecords: Bool { self == .parsed }

    /// Missing, truncated, corrupt, incompatible, or tool failures — never
    /// treatable as successful verification evidence.
    var blocksSuccessfulVerification: Bool {
        switch self {
        case .parsed:
            return false
        case .missingBundle, .incompleteBundle, .corruptBundle,
             .schemaMismatch, .toolFailed, .unavailable:
            return true
        }
    }
}

/// One workflow-safe issue row. Contains local paths and messages only —
/// never ticket keys, MR fields, or company page content.
nonisolated struct TicketWorkflowResultIssuePresentation: Equatable, Sendable, Identifiable {
    var id: String
    var kind: IOSResultIssueKind
    var message: String
    var fileURL: URL?
    var line: Int?
    var testIdentifier: String?
    /// Bounded single-line label for checklist / detail UI.
    var displayText: String

    init(issue: IOSResultIssue, index: Int) {
        self.kind = issue.kind
        self.message = issue.message
        self.fileURL = issue.fileURL
        self.line = issue.line
        self.testIdentifier = issue.testIdentifier
        self.displayText = IOSBuildJobPresentation.firstIssueText(issue) ?? issue.message
        let location = issue.fileURL?.path ?? issue.testIdentifier ?? "none"
        self.id = "\(index)-\(issue.kind.rawValue)-\(location)-\(issue.message.prefix(64))"
    }
}

/// Presentation of a Console-owned job result for Ticket Work detail / job
/// panels. Built only from ``IOSResultSummary`` and local URLs — no ticket or
/// MR fields.
nonisolated struct TicketWorkflowResultPresentation: Equatable, Sendable {
    var availability: TicketWorkflowResultAvailability
    /// Structured record outcome when parsed; otherwise `.unknown`.
    var recordOutcome: IOSResultOutcome
    var issues: [TicketWorkflowResultIssuePresentation]
    var errorCount: Int
    var failedTestCount: Int
    var diagnosticMessage: String?
    var firstIssueText: String?
    var errorCopyText: String?
    var resultBundleURL: URL?
    var sourceURL: URL?
    var failedTestIdentifiers: [String]
    var canOpenResult: Bool
    var canOpenSource: Bool
    var canCopyError: Bool
    var canRerunFailedTests: Bool
    /// True only when structured records parsed cleanly and report success.
    /// Never true for missing/corrupt/incompatible/truncated/unavailable results.
    var isSuccessfulVerification: Bool
    /// Step outcome Ticket Work should apply for verification evidence.
    /// Unreadable results map to ``TicketStepOutcome/unverified`` or
    /// ``TicketStepOutcome/failed``, never ``TicketStepOutcome/succeeded``.
    var verificationOutcome: TicketStepOutcome
}
