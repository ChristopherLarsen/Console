import Foundation

/// How Console classified the `.xcresult` inspection. Parser problems never
/// invent a passing result record.
nonisolated enum IOSResultParseStatus: String, Equatable, Sendable {
    case parsed
    case missingBundle
    case incompleteBundle
    case corruptBundle
    case schemaMismatch
    case toolFailed
}

/// Outcome taken from structured xcresulttool records, never from log wording.
nonisolated enum IOSResultOutcome: String, Equatable, Sendable {
    case succeeded
    case failed
    case unknown
}

nonisolated enum IOSResultIssueKind: String, Equatable, Sendable {
    case buildError
    case testFailure
}

/// One bounded, locally recorded build error or test failure.
nonisolated struct IOSResultIssue: Equatable, Sendable {
    var kind: IOSResultIssueKind
    var message: String
    var fileURL: URL?
    var line: Int?
    var testIdentifier: String?
}

/// Local summary of an `.xcresult`. Bundles stay on disk; nothing here is
/// uploaded or forwarded to an LLM.
nonisolated struct IOSResultSummary: Equatable, Sendable {
    var parseStatus: IOSResultParseStatus
    var outcome: IOSResultOutcome
    var issues: [IOSResultIssue]
    var errorCount: Int
    var failedTestCount: Int
    var diagnosticMessage: String?

    static let maxIssues = 25

    /// True only when structured records were parsed and they report failure.
    /// Missing, corrupt, or mismatched bundles return false so a parser error
    /// cannot invent success — and cannot be the sole reason a job is marked
    /// successful either. The coordinator never promotes `.failed` to
    /// `.succeeded` on this flag.
    var recordsIndicateFailure: Bool {
        guard parseStatus == .parsed else { return false }
        if outcome == .failed { return true }
        if errorCount > 0 || failedTestCount > 0 { return true }
        return issues.contains { $0.kind == .buildError || $0.kind == .testFailure }
    }

    static func parsed(
        outcome: IOSResultOutcome,
        issues: [IOSResultIssue],
        errorCount: Int? = nil,
        failedTestCount: Int? = nil,
        diagnosticMessage: String? = nil
    ) -> IOSResultSummary {
        let bounded = Array(issues.prefix(Self.maxIssues))
        return IOSResultSummary(
            parseStatus: .parsed,
            outcome: outcome,
            issues: bounded,
            errorCount: errorCount ?? bounded.filter { $0.kind == .buildError }.count,
            failedTestCount: failedTestCount ?? bounded.filter { $0.kind == .testFailure }.count,
            diagnosticMessage: diagnosticMessage
        )
    }

    static func unparsed(
        _ status: IOSResultParseStatus,
        message: String
    ) -> IOSResultSummary {
        IOSResultSummary(
            parseStatus: status,
            outcome: .unknown,
            issues: [],
            errorCount: 0,
            failedTestCount: 0,
            diagnosticMessage: message
        )
    }
}
