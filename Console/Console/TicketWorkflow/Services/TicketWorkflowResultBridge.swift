import Foundation

/// Bridges ``IOSResultSummary`` into Ticket Work presentation and evidence
/// outcomes without re-parsing xcresult bundles. Reuses
/// ``IOSBuildJobPresentation`` / ``IOSFailedTestIdentifier`` helpers for
/// Open Result, Open Source, Copy Error, and Rerun Failed Tests selection.
nonisolated enum TicketWorkflowResultBridge {

    // MARK: - Presentation

    /// Map a job's local result summary into workflow-safe presentation.
    /// `jobErrorMessage` is the process-level error string only (never a log dump).
    static func makePresentation(
        summary: IOSResultSummary?,
        resultBundleURL: URL?,
        jobState: IOSBuildJobState = .succeeded,
        jobErrorMessage: String? = nil,
        bundleExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> TicketWorkflowResultPresentation {
        let availability: TicketWorkflowResultAvailability
        if let summary {
            availability = TicketWorkflowResultAvailability(parseStatus: summary.parseStatus)
        } else {
            availability = .unavailable
        }

        let issues = (summary?.issues ?? []).enumerated().map {
            TicketWorkflowResultIssuePresentation(issue: $0.element, index: $0.offset)
        }
        let firstIssue = summary?.issues.first
        let sourceURL = summary?.issues.compactMap(\.fileURL).first
        let existingBundle: URL? = {
            guard let resultBundleURL, bundleExists(resultBundleURL) else { return nil }
            return resultBundleURL
        }()
        let failedIDs: [String] = {
            guard let summary else { return [] }
            return failedTestIdentifiers(from: summary)
        }()
        let diagnostic: String? = {
            guard let summary else { return nil }
            switch summary.parseStatus {
            case .parsed:
                return nil
            case .missingBundle, .incompleteBundle, .corruptBundle, .schemaMismatch, .toolFailed:
                return IOSProjectProfile.nilIfEmpty(summary.diagnosticMessage)
            }
        }()
        let errorCopy = errorCopyText(
            firstIssue: firstIssue,
            jobErrorMessage: jobErrorMessage,
            diagnostic: diagnostic
        )
        let verification = verificationOutcome(jobState: jobState, summary: summary)

        return TicketWorkflowResultPresentation(
            availability: availability,
            recordOutcome: summary?.outcome ?? .unknown,
            issues: issues,
            errorCount: summary?.errorCount ?? 0,
            failedTestCount: summary?.failedTestCount ?? 0,
            diagnosticMessage: diagnostic,
            firstIssueText: IOSBuildJobPresentation.firstIssueText(firstIssue),
            errorCopyText: errorCopy,
            resultBundleURL: existingBundle,
            sourceURL: sourceURL,
            failedTestIdentifiers: failedIDs,
            canOpenResult: existingBundle != nil,
            canOpenSource: sourceURL != nil || existingBundle != nil,
            canCopyError: errorCopy != nil,
            canRerunFailedTests: !failedIDs.isEmpty,
            isSuccessfulVerification: verification == .succeeded,
            verificationOutcome: verification
        )
    }

    /// Convenience when the caller already has an ``IOSBuildJob``.
    static func makePresentation(
        job: IOSBuildJob,
        bundleExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> TicketWorkflowResultPresentation {
        makePresentation(
            summary: job.resultSummary,
            resultBundleURL: job.resultBundleURL,
            jobState: job.state,
            jobErrorMessage: job.errorMessage,
            bundleExists: bundleExists
        )
    }

    // MARK: - Verification evidence

    /// Step outcome for verification evidence from job terminal state + result
    /// summary. Missing, incomplete (truncated), corrupt, schema-mismatched,
    /// tool-failed, or absent summaries never yield ``TicketStepOutcome/succeeded``.
    static func verificationOutcome(
        jobState: IOSBuildJobState,
        summary: IOSResultSummary?
    ) -> TicketStepOutcome {
        switch jobState {
        case .queued, .running:
            return .running
        case .cancelled, .timedOut, .failed:
            return .failed
        case .succeeded:
            return succeededJobVerificationOutcome(summary: summary)
        }
    }

    /// Refine Package C's fingerprint-aware outcome so unreadable results
    /// cannot remain ``TicketStepOutcome/succeeded``.
    static func refineEvidenceOutcome(
        _ outcome: TicketStepOutcome,
        jobState: IOSBuildJobState,
        summary: IOSResultSummary?
    ) -> TicketStepOutcome {
        let fromResult = verificationOutcome(jobState: jobState, summary: summary)
        switch (outcome, fromResult) {
        case (.succeeded, .succeeded):
            return .succeeded
        case (.succeeded, let refined):
            // Package C thought the job succeeded; result honesty demotes it.
            return refined
        case (.running, _):
            return fromResult == .running ? .running : fromResult
        case (.failed, _):
            return .failed
        case (.unverified, .failed):
            return .failed
        case (.unverified, _):
            return .unverified
        default:
            // Prefer the stricter of the two when combining.
            if fromResult == .failed || outcome == .failed { return .failed }
            if fromResult == .unverified || outcome == .unverified { return .unverified }
            return fromResult
        }
    }

    /// Build an ``ApplyJobEvidence`` event, applying Package C fingerprint
    /// rules then demoting success when the result bundle is unreadable.
    static func makeApplyEvent(
        evidence: TicketJobEvidence,
        resultSummary: IOSResultSummary?,
        currentFingerprint: TicketSourceFingerprint,
        eventID: UUID = UUID(),
        at: Date = Date()
    ) -> ApplyJobEvidence {
        var event = TicketJobEvidenceMapper.makeEvent(
            evidence: evidence,
            currentFingerprint: currentFingerprint,
            eventID: eventID,
            at: at
        )
        event.outcome = refineEvidenceOutcome(
            event.outcome,
            jobState: evidence.jobState,
            summary: resultSummary
        )
        return event
    }

    /// True only when the job succeeded, the fingerprint is current, and the
    /// result summary is a clean structured success.
    static func isAcceptableForAdvancement(
        evidence: TicketJobEvidence,
        resultSummary: IOSResultSummary?,
        currentFingerprint: TicketSourceFingerprint
    ) -> Bool {
        guard TicketBuildJobAdapter.isAcceptableForAdvancement(
            evidence: evidence,
            currentFingerprint: currentFingerprint
        ) else {
            return false
        }
        return verificationOutcome(jobState: evidence.jobState, summary: resultSummary) == .succeeded
    }

    // MARK: - Action helpers (pure; wrap existing IOS panel behaviors)

    /// URL for "Open Result in Xcode", or `nil` when the bundle is absent.
    static func resultURLToOpen(
        from presentation: TicketWorkflowResultPresentation
    ) -> URL? {
        guard presentation.canOpenResult else { return nil }
        return presentation.resultBundleURL
    }

    /// URL for "Open Source Location". Falls back to the result bundle when
    /// no issue file URL is available (same as ``IOSBuildJobPanelModel``).
    static func sourceURLToOpen(
        from presentation: TicketWorkflowResultPresentation
    ) -> URL? {
        if let sourceURL = presentation.sourceURL {
            return sourceURL
        }
        return presentation.resultBundleURL
    }

    /// Clipboard text for "Copy Error" — issue message, then job error, then
    /// diagnostic. Never a log dump.
    static func errorTextToCopy(
        from presentation: TicketWorkflowResultPresentation
    ) -> String? {
        presentation.errorCopyText
    }

    /// Validated failed-test identifiers for "Rerun Failed Tests", taken only
    /// from structured result issues via ``IOSFailedTestIdentifier``.
    static func failedTestIdentifiers(from summary: IOSResultSummary) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for issue in summary.issues where issue.kind == .testFailure {
            guard let identifier = IOSFailedTestIdentifier.validated(issue.testIdentifier) else {
                continue
            }
            if seen.insert(identifier).inserted {
                ordered.append(identifier)
            }
        }
        return ordered
    }

    /// Selection for re-running only validated failures — no original test plan.
    static func rerunFailedTestSelection(
        from summary: IOSResultSummary
    ) -> IOSTestSelection? {
        let identifiers = failedTestIdentifiers(from: summary)
        guard !identifiers.isEmpty else { return nil }
        return IOSTestSelection(identifiers: identifiers, testPlan: nil)
    }

    static func performOpenResult(
        presentation: TicketWorkflowResultPresentation,
        opener: any IOSWorkspaceOpening
    ) {
        guard let url = resultURLToOpen(from: presentation) else { return }
        opener.open(url)
    }

    static func performOpenSource(
        presentation: TicketWorkflowResultPresentation,
        opener: any IOSWorkspaceOpening
    ) {
        guard let url = sourceURLToOpen(from: presentation) else { return }
        opener.open(url)
    }

    static func performCopyError(
        presentation: TicketWorkflowResultPresentation,
        pasteboard: any IOSPasteboardWriting
    ) {
        guard let text = errorTextToCopy(from: presentation) else { return }
        pasteboard.write(text)
    }

    // MARK: - Private

    private static func succeededJobVerificationOutcome(
        summary: IOSResultSummary?
    ) -> TicketStepOutcome {
        guard let summary else {
            return .unverified
        }
        switch summary.parseStatus {
        case .missingBundle, .incompleteBundle, .corruptBundle,
             .schemaMismatch, .toolFailed:
            return .unverified
        case .parsed:
            if summary.recordsIndicateFailure {
                return .failed
            }
            switch summary.outcome {
            case .succeeded:
                return .succeeded
            case .failed:
                return .failed
            case .unknown:
                return .unverified
            }
        }
    }

    /// Mirrors ``IOSBuildJobPresentation.errorCopyText`` without requiring a job.
    private static func errorCopyText(
        firstIssue: IOSResultIssue?,
        jobErrorMessage: String?,
        diagnostic: String?
    ) -> String? {
        if let issue = firstIssue {
            let message = issue.message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty { return message }
        }
        if let errorMessage = IOSProjectProfile.nilIfEmpty(jobErrorMessage) {
            return errorMessage
        }
        return IOSProjectProfile.nilIfEmpty(diagnostic)
    }
}
