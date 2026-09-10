import Foundation

/// How a write dispatch ended, which decides between safe retry, unknown
/// outcome, and completed-with-verification. The distinction comes from
/// `ClaudeServiceError.launchFailed` (nothing ran) versus every failure after
/// dispatch (the run may have acted).
enum JiraWriteDispatchOutcome: Sendable {
    case completed(JiraStructuredResult)
    case possiblyApplied(reason: String)
    case notDispatched(reason: String)
}

/// `JiraOperations` implemented on top of the managed headless Claude
/// service.
///
/// Reads: validated typed results, bounded transient retries, coalescing of
/// identical in-flight reads. Writes: fetch current state, resolve the exact
/// target transition, apply it, read back and verify. A timeout,
/// disconnection, or cancellation after possible mutation is an unknown
/// outcome: it is reconciled with a fresh read before any retry decision,
/// and interrupted write turns are never auto-resumed. Late or misrouted
/// responses cannot update a different ticket — every structured payload's
/// ticket key is verified against the request.
struct ClaudeJiraOperations: JiraOperations {
    let service: ManagedClaudeService
    /// Bounded retry budget for transient read failures.
    var readRetryAttempts: Int = 2
    /// Backoff between read retries.
    var readRetryBackoff: TimeInterval = 0.5
    var connection: JiraConnectionIdentity
    var coalescer = JiraReadCoalescer()

    /// Injectable for tests; production sleeps the current task.
    var backoffSleeper: @Sendable (TimeInterval) async -> Void = { interval in
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }

    // MARK: Reads

    func lookupIssue(_ key: String, context: JiraOperationContext) async throws -> JiraIssueSnapshot {
        try JiraLLMPolicyGate.ensureLLMTransportAllowed(context.connection)
        return try await coalescer.coalescedSnapshot(key: key) {
            try await fetchSnapshot(key: key, context: context)
        }
    }

    func currentStatus(of key: String, context: JiraOperationContext) async throws -> JiraIssueStatus {
        try await lookupIssue(key, context: context).status
    }

    private func fetchSnapshot(key: String, context: JiraOperationContext) async throws -> JiraIssueSnapshot {
        try await withBoundedRetries("lookup") {
            let output: ClaudeOperationOutput
            do {
                output = try await self.runOperation(
                    operationName: "lookup",
                    ticketKey: key,
                    promptInstruction: """
                    Report the current status of JIRA issue \(key). Use the configured JIRA \
                    tools if available; otherwise answer from the personal-instance data you \
                    can access.
                    """,
                    context: context
                )
            } catch let error as ClaudeServiceError {
                throw Self.readError(from: error)
            }
            let structured = try Self.decodeVerified(output: output, operation: "lookup", expectedTicketKey: key)
            guard let statusName = structured.statusName else {
                throw JiraOperationsError.unexpectedSchema(
                    expected: JiraOperationContext.schemaVersion,
                    receivedDescription: "lookup result missing statusName"
                )
            }
            return JiraIssueSnapshot(key: key, status: JiraIssueStatus(name: statusName))
        }
    }

    func availableTransitions(for key: String, context: JiraOperationContext) async throws -> [JiraTransition] {
        try JiraLLMPolicyGate.ensureLLMTransportAllowed(context.connection)
        return try await withBoundedRetries("transitions") {
            let output: ClaudeOperationOutput
            do {
                output = try await self.runOperation(
                    operationName: "transitions",
                    ticketKey: key,
                    promptInstruction: """
                    List the currently available workflow transitions for JIRA issue \(key), \
                    including each transition's id, name, and target status name.
                    """,
                    context: context
                )
            } catch let error as ClaudeServiceError {
                throw Self.readError(from: error)
            }
            let structured = try Self.decodeVerified(output: output, operation: "transitions", expectedTicketKey: key)
            return (structured.transitions ?? []).map {
                JiraTransition(id: $0.id, name: $0.name, targetStatusName: $0.targetStatusName)
            }
        }
    }

    func searchTickets(matching query: String, limit: Int, context: JiraOperationContext) async throws -> [JiraIssueSummary] {
        try JiraLLMPolicyGate.ensureLLMTransportAllowed(context.connection)
        // Search is bounded regardless of what the caller passes.
        let boundedLimit = min(max(1, limit), 50)
        return try await withBoundedRetries("search") {
            let output: ClaudeOperationOutput
            do {
                output = try await self.runOperation(
                    operationName: "search",
                    ticketKey: nil,
                    promptInstruction: """
                    Find up to \(boundedLimit) JIRA issues matching this query and report each \
                    issue's key and current status name. Query: \(query)
                    """,
                    context: context
                )
            } catch let error as ClaudeServiceError {
                throw Self.readError(from: error)
            }
            let structured = try Self.decodeVerified(output: output, operation: "search", expectedTicketKey: nil)
            return (structured.results ?? []).map {
                JiraIssueSummary(key: $0.key, statusName: $0.statusName)
            }
        }
    }

    // MARK: Writes

    func transition(_ key: String, to targetStatusName: String, context: JiraOperationContext) async throws -> JiraTransitionResult {
        try JiraLLMPolicyGate.ensureLLMTransportAllowed(context.connection)
        var attempts = 0
        var lastError: JiraOperationsError?
        while attempts < 2 {
            attempts += 1
            do {
                return try await attemptTransition(key: key, to: targetStatusName, context: context)
            } catch let error as JiraOperationsError {
                switch error {
                case .transientFailure:
                    // Nothing was dispatched, so a bounded retry of the whole
                    // write flow is safe.
                    lastError = error
                    await backoffSleeper(readRetryBackoff)
                case .writeOutcomeUnknown:
                    // Never auto-resume an interrupted write turn.
                    throw error
                default:
                    throw error
                }
            }
        }
        throw lastError ?? JiraOperationsError.transientFailure(reason: "transition exhausted retries")
    }

    private func attemptTransition(
        key: String,
        to targetStatusName: String,
        context: JiraOperationContext
    ) async throws -> JiraTransitionResult {
        // 1. Fetch current state and available transitions.
        let snapshot = try await lookupIssue(key, context: context)
        let transitions = try await availableTransitions(for: key, context: context)
        guard let transition = Self.resolveExactTransition(
            from: transitions,
            targetStatusName: targetStatusName
        ) else {
            throw JiraOperationsError.transitionTargetUnavailable(key: key, targetStatusName: targetStatusName)
        }

        // 2. Perform the transition.
        let dispatch = try await performTransitionOp(
            key: key,
            transitionID: transition.id,
            context: context
        )

        // 3. Read back and verify / reconcile.
        switch dispatch {
        case .completed(let structured):
            guard structured.appliedTransitionID == nil
                || structured.appliedTransitionID == transition.id else {
                throw JiraOperationsError.unexpectedSchema(
                    expected: JiraOperationContext.schemaVersion,
                    receivedDescription: "transition result named a different transition"
                )
            }
            return try await verifyTransition(
                key: key,
                targetStatusName: targetStatusName,
                fromStatusName: snapshot.status.name,
                transitionID: transition.id,
                context: context,
                reconciled: false
            )

        case .possiblyApplied(let reason):
            // Unknown outcome: reconcile with a fresh read before deciding.
            return try await reconcileAfterPossibleApply(
                key: key,
                targetStatusName: targetStatusName,
                fromStatusName: snapshot.status.name,
                transitionID: transition.id,
                dispatchReason: reason,
                context: context
            )

        case .notDispatched(let reason):
            throw JiraOperationsError.transientFailure(reason: reason)
        }
    }

    /// Single fresh read to resolve an unknown write outcome. Never retries
    /// the write here: if the read fails, the outcome stays unknown.
    private func reconcileAfterPossibleApply(
        key: String,
        targetStatusName: String,
        fromStatusName: String,
        transitionID: String,
        dispatchReason: String,
        context: JiraOperationContext
    ) async throws -> JiraTransitionResult {
        let reconcileContext = context.refreshedContext(within: service.configuration.requestTimeout)
        let observed: JiraIssueStatus
        do {
            observed = try await lookupIssue(key, context: reconcileContext).status
        } catch {
            throw JiraOperationsError.writeOutcomeUnknown(key: key, correlationID: reconcileContext.correlationID)
        }
        if JiraStatusNormalizer.areEquivalent(observed.name, targetStatusName) {
            return JiraTransitionResult(
                ticketKey: key,
                transitionID: transitionID,
                fromStatusName: fromStatusName,
                toStatusName: targetStatusName,
                verified: false,
                reconciled: true
            )
        }
        // The fresh read is ground truth: the ticket is neither at the target
        // nor where it started, or it simply never moved. Either way this is
        // not a verified success — surface it, never silently retry.
        throw JiraOperationsError.verificationFailed(
            key: key,
            expectedStatusName: targetStatusName,
            observedStatusName: observed.name
        )
    }

    private func verifyTransition(
        key: String,
        targetStatusName: String,
        fromStatusName: String,
        transitionID: String,
        context: JiraOperationContext,
        reconciled: Bool
    ) async throws -> JiraTransitionResult {
        let verifyContext = context.refreshedContext(within: service.configuration.requestTimeout)
        let observed: JiraIssueStatus
        do {
            observed = try await lookupIssue(key, context: verifyContext).status
        } catch {
            // We know the transition command was accepted; a failed
            // verification read is an unknown outcome, not a verified success.
            throw JiraOperationsError.writeOutcomeUnknown(key: key, correlationID: verifyContext.correlationID)
        }
        guard JiraStatusNormalizer.areEquivalent(observed.name, targetStatusName) else {
            throw JiraOperationsError.verificationFailed(
                key: key,
                expectedStatusName: targetStatusName,
                observedStatusName: observed.name
            )
        }
        return JiraTransitionResult(
            ticketKey: key,
            transitionID: transitionID,
            fromStatusName: fromStatusName,
            toStatusName: targetStatusName,
            verified: true,
            reconciled: reconciled
        )
    }

    private func performTransitionOp(
        key: String,
        transitionID: String,
        context: JiraOperationContext
    ) async throws -> JiraWriteDispatchOutcome {
        let output: ClaudeOperationOutput
        do {
            output = try await runOperation(
                operationName: "transition",
                ticketKey: key,
                promptInstruction: """
                Apply the workflow transition with id \(transitionID) to JIRA issue \(key). \
                Do not perform any other mutation.
                """,
                context: context
            )
        } catch let error as ClaudeServiceError {
            return Self.dispatchOutcome(from: error)
        }
        do {
            let structured = try Self.decodeVerified(output: output, operation: "transition", expectedTicketKey: key)
            return .completed(structured)
        } catch {
            // The run dispatched and may have applied the transition even
            // though its answer was unusable.
            return .possiblyApplied(reason: "transition response could not be verified")
        }
    }

    /// Maps a service error to a write dispatch outcome.
    nonisolated static func dispatchOutcome(from error: ClaudeServiceError) -> JiraWriteDispatchOutcome {
        switch error {
        case .executableUnavailable, .notPrepared, .unsupportedFlags, .launchFailed, .shuttingDown:
            return .notDispatched(reason: "the run never started")
        case .needsAuthentication(let reason):
            return .notDispatched(reason: reason)
        case .timedOut, .cancelled, .executionFailed, .malformedOutput:
            return .possiblyApplied(reason: "the run was dispatched and its outcome is unknown")
        }
    }

    /// Resolves the exact transition whose target status matches, with
    /// whitespace/case tolerance. Ambiguity is a failure, never a guess.
    nonisolated static func resolveExactTransition(
        from transitions: [JiraTransition],
        targetStatusName: String
    ) -> JiraTransition? {
        let matches = transitions.filter {
            JiraStatusNormalizer.areEquivalent($0.targetStatusName, targetStatusName)
        }
        guard matches.count == 1, let match = matches.first else { return nil }
        return match
    }

    // MARK: Shared plumbing

    private func runOperation(
        operationName: String,
        ticketKey: String?,
        promptInstruction: String,
        context: JiraOperationContext
    ) async throws -> ClaudeOperationOutput {
        let schemaJSON = Self.schemaJSON
        let prompt = """
        \(promptInstruction)

        Respond with only a JSON object of this exact shape:
        {"schemaVersion":\(JiraOperationContext.schemaVersion),"correlationID":"\(context.correlationID.uuidString)","operation":"\(operationName)"\(ticketKey.map { ",\"ticketKey\":\"\($0)\"" } ?? "")}
        Add the fields this operation requires (statusName, transitions, results, appliedTransitionID).
        """
        return try await service.perform(
            ClaudeOperationInvocation(
                correlationID: context.correlationID,
                prompt: prompt,
                expectedSchemaJSON: schemaJSON,
                ephemeral: true,
                deadline: context.deadline
            )
        )
    }

    static let schemaJSON = #"{"type":"object","properties":{"schemaVersion":{"type":"integer"},"correlationID":{"type":"string"},"operation":{"type":"string"},"ticketKey":{"type":"string"},"statusName":{"type":"string"},"transitions":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"},"targetStatusName":{"type":"string"}},"required":["id","name","targetStatusName"]}},"results":{"type":"array","items":{"type":"object","properties":{"key":{"type":"string"},"statusName":{"type":"string"}},"required":["key","statusName"]}},"appliedTransitionID":{"type":"string"}},"required":["schemaVersion","correlationID","operation"]}"#

    private func withBoundedRetries<T>(
        _ operation: String,
        _ body: () async throws -> T
    ) async throws -> T {
        var lastError: JiraOperationsError?
        for attempt in 0...readRetryAttempts {
            do {
                return try await body()
            } catch let error as JiraOperationsError {
                guard Self.isTransient(error), attempt < readRetryAttempts else { throw error }
                lastError = error
                await backoffSleeper(readRetryBackoff * Double(attempt + 1))
            }
        }
        throw lastError ?? JiraOperationsError.transientFailure(reason: "retry loop exhausted")
    }

    /// Which failures are safe to retry for reads: they cannot have mutated
    /// anything (or, for reads, mutation is impossible), so a bounded retry
    /// is safe.
    nonisolated static func isTransient(_ error: JiraOperationsError) -> Bool {
        switch error {
        case .transientFailure, .timedOut, .cancelled, .connectionUnavailable:
            return true
        case .policyBlocked, .needsAuthentication, .unexpectedSchema, .ticketNotFound,
             .transitionTargetUnavailable, .writeOutcomeUnknown, .verificationFailed, .mismatchedTicket:
            return false
        }
    }

    /// Maps a `ClaudeServiceError` onto the operations error domain for
    /// reads. Dispatch ambiguity does not exist for reads (nothing mutates),
    /// so post-dispatch failures are transient.
    nonisolated static func readError(from error: ClaudeServiceError) -> JiraOperationsError {
        switch error {
        case .executableUnavailable, .notPrepared, .launchFailed, .unsupportedFlags, .shuttingDown:
            return .connectionUnavailable(reason: ManagedClaudeService.errorDescription(for: error))
        case .needsAuthentication:
            return .needsAuthentication
        case .timedOut(let correlationID):
            return .timedOut(correlationID: correlationID)
        case .cancelled:
            return .cancelled
        case .executionFailed(let reason):
            return .transientFailure(reason: reason)
        case .malformedOutput(let reason):
            return .transientFailure(reason: reason)
        }
    }

    private nonisolated static func decodeVerified(
        output: ClaudeOperationOutput,
        operation: String,
        expectedTicketKey: String?
    ) throws -> JiraStructuredResult {
        do {
            let structured = try JiraStructuredResultDecoder.decode(output.resultText)
            guard structured.schemaVersion == JiraOperationContext.schemaVersion else {
                throw JiraOperationsError.unexpectedSchema(
                    expected: JiraOperationContext.schemaVersion,
                    receivedDescription: "schemaVersion \(structured.schemaVersion)"
                )
            }
            guard structured.correlationID == output.correlationID else {
                throw JiraOperationsError.unexpectedSchema(
                    expected: JiraOperationContext.schemaVersion,
                    receivedDescription: "correlationID did not echo the request"
                )
            }
            guard structured.operation == operation else {
                throw JiraOperationsError.unexpectedSchema(
                    expected: JiraOperationContext.schemaVersion,
                    receivedDescription: "operation was \(structured.operation)"
                )
            }
            if let expectedTicketKey {
                guard let received = structured.ticketKey else {
                    throw JiraOperationsError.unexpectedSchema(
                        expected: JiraOperationContext.schemaVersion,
                        receivedDescription: "ticketKey missing"
                    )
                }
                guard JiraStatusNormalizer.areEquivalent(received, expectedTicketKey) else {
                    throw JiraOperationsError.mismatchedTicket(expected: expectedTicketKey, received: received)
                }
            }
            return structured
        } catch let error as JiraOperationsError {
            throw error
        } catch {
            throw JiraOperationsError.unexpectedSchema(
                expected: JiraOperationContext.schemaVersion,
                receivedDescription: String(describing: error)
            )
        }
    }
}

// MARK: - Read coalescing

/// Coalesces identical in-flight issue reads so concurrent callers share one
/// run. Only reads coalesce; writes never do.
actor JiraReadCoalescer {
    private var inFlight: [String: Task<JiraIssueSnapshot, Error>] = [:]

    func coalescedSnapshot(
        key: String,
        make: @escaping @Sendable () async throws -> JiraIssueSnapshot
    ) async throws -> JiraIssueSnapshot {
        if let existing = inFlight[key] {
            return try await existing.value
        }
        let task = Task {
            try await make()
        }
        inFlight[key] = task
        defer {
            if inFlight[key] == task { inFlight[key] = nil }
        }
        return try await task.value
    }
}
