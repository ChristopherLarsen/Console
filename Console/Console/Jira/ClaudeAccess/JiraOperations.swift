import Foundation

// MARK: - Data boundary

/// Which JIRA instance a request targets. This is the security boundary the
/// whole Claude-access feature is built around.
///
/// Company JIRA content is DOM-only inside Console's WebViews and must never
/// reach any LLM, MCP server, or external service. Only the personal
/// instance boundary may be routed through the managed headless Claude
/// transport, and only with synthetic or personal-site data.
enum JiraDataBoundary: String, Codable, Equatable, Sendable, CaseIterable {
    /// Personal site / synthetic fixtures. LLM transport permitted.
    case personalInstance
    /// Company instance rendered in Console's WebView. DOM-only; LLM
    /// transport is refused by policy, never by configuration.
    case companyInstance
}

/// Opaque identity of the JIRA connection a request belongs to. Carried on
/// every request so results can be attributed and so the policy gate can
/// refuse cross-boundary routing before anything leaves the process.
struct JiraConnectionIdentity: Equatable, Hashable, Codable, Sendable {
    let hostIdentifier: String
    let boundary: JiraDataBoundary

    init(hostIdentifier: String, boundary: JiraDataBoundary) {
        self.hostIdentifier = hostIdentifier
        self.boundary = boundary
    }
}

// MARK: - Operation context

/// Everything a single JIRA operation carries besides its payload: the
/// correlation ID, the connection identity, the deadline, and the expected
/// structured-result schema version.
struct JiraOperationContext: Equatable, Sendable {
    /// Version of the JSON contract the managed Claude transport must answer
    /// with. Results that do not declare this version are rejected.
    static let schemaVersion = 1

    let correlationID: UUID
    let connection: JiraConnectionIdentity
    let deadline: Date

    init(connection: JiraConnectionIdentity, deadline: Date, correlationID: UUID = UUID()) {
        self.correlationID = correlationID
        self.connection = connection
        self.deadline = deadline
    }

    /// A context with the same connection but a fresh correlation ID and a
    /// fresh deadline, used for reconciliation reads.
    func refreshedContext(within timeout: TimeInterval) -> JiraOperationContext {
        JiraOperationContext(
            connection: connection,
            deadline: Date().addingTimeInterval(timeout),
            correlationID: UUID()
        )
    }
}

// MARK: - Typed results

struct JiraIssueStatus: Equatable, Sendable {
    let name: String
}

struct JiraTransition: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let targetStatusName: String
}

struct JiraIssueSnapshot: Equatable, Sendable {
    let key: String
    let status: JiraIssueStatus
}

struct JiraIssueSummary: Equatable, Sendable {
    let key: String
    let statusName: String
}

/// Result of a verified transition. `verified` is true only when a fresh read
/// after the transition observed the target status; reconciled successes
/// (unknown outcome, then a confirming read) report `verified: false` via the
/// `reconciled` flag.
struct JiraTransitionResult: Equatable, Sendable {
    let ticketKey: String
    let transitionID: String
    let fromStatusName: String
    let toStatusName: String
    let verified: Bool
    let reconciled: Bool
}

// MARK: - Errors

enum JiraOperationsError: Error, Equatable, Sendable {
    /// The connection's data boundary forbids LLM transport. Not retryable,
    /// not configurable — this is the binding security boundary.
    case policyBlocked(boundary: JiraDataBoundary)
    case timedOut(correlationID: UUID)
    case cancelled
    case needsAuthentication
    case connectionUnavailable(reason: String)
    /// Bounded-retryable failure that cannot have mutated anything.
    case transientFailure(reason: String)
    case unexpectedSchema(expected: Int, receivedDescription: String?)
    case ticketNotFound(key: String)
    case transitionTargetUnavailable(key: String, targetStatusName: String)
    /// A write may or may not have been applied; a fresh read could not
    /// resolve the ambiguity. Never auto-retried.
    case writeOutcomeUnknown(key: String, correlationID: UUID)
    case verificationFailed(key: String, expectedStatusName: String, observedStatusName: String)
    /// A response arrived for a different ticket than the request. Late or
    /// misrouted responses must never be applied to another ticket.
    case mismatchedTicket(expected: String, received: String)
}

// MARK: - Operations contract

/// Typed JIRA operations Console performs through the managed headless Claude
/// transport. Read operations validate and decode structured results; the
/// write operation is a full state machine: fetch state, resolve the exact
/// transition, apply, then read back and verify.
protocol JiraOperations: Sendable {
    func lookupIssue(_ key: String, context: JiraOperationContext) async throws -> JiraIssueSnapshot
    func currentStatus(of key: String, context: JiraOperationContext) async throws -> JiraIssueStatus
    func availableTransitions(for key: String, context: JiraOperationContext) async throws -> [JiraTransition]
    func transition(_ key: String, to targetStatusName: String, context: JiraOperationContext) async throws -> JiraTransitionResult
    func searchTickets(matching query: String, limit: Int, context: JiraOperationContext) async throws -> [JiraIssueSummary]
}

// MARK: - Policy gate

/// Central, non-bypassable enforcement of the DOM-only boundary. Every
/// `JiraOperations` entry point calls this first; company-instance
/// connections are refused before any prompt is built or any process starts.
enum JiraLLMPolicyGate {
    static func ensureLLMTransportAllowed(_ connection: JiraConnectionIdentity) throws {
        guard connection.boundary == .personalInstance else {
            throw JiraOperationsError.policyBlocked(boundary: connection.boundary)
        }
    }
}

// MARK: - Status normalization

/// Status names are compared with whitespace/case tolerance so transition
/// resolution and read-back verification do not fail on formatting variants.
enum JiraStatusNormalizer {
    static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func areEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        normalized(lhs) == normalized(rhs)
    }
}

// MARK: - Structured result contract

/// The JSON payload the managed Claude run must answer with for every JIRA
/// operation. The prompt for each operation instructs Claude to emit exactly
/// this shape; decoding here is authoritative.
struct JiraStructuredResult: Codable, Equatable, Sendable {
    struct PayloadTransition: Codable, Equatable, Sendable {
        let id: String
        let name: String
        let targetStatusName: String
    }

    struct PayloadSummary: Codable, Equatable, Sendable {
        let key: String
        let statusName: String
    }

    let schemaVersion: Int
    let correlationID: UUID
    let operation: String
    let ticketKey: String?
    let statusName: String?
    let transitions: [PayloadTransition]?
    let results: [PayloadSummary]?
    let appliedTransitionID: String?
}

enum JiraStructuredResultDecodingError: Error, Equatable, Sendable {
    case noJSONPayload
    case invalidJSON(description: String)
}

enum JiraStructuredResultDecoder {
    /// Decodes the structured payload from a headless result string. Tolerates
    /// Markdown code fences some models wrap JSON in.
    static func decode(_ text: String?) throws -> JiraStructuredResult {
        guard let payload = Self.jsonPayload(from: text) else {
            throw JiraStructuredResultDecodingError.noJSONPayload
        }
        do {
            return try JSONDecoder().decode(JiraStructuredResult.self, from: Data(payload.utf8))
        } catch {
            throw JiraStructuredResultDecodingError.invalidJSON(description: String(describing: error))
        }
    }

    /// Extracts the outermost JSON object from a result string, stripping
    /// code fences and any surrounding prose. Contains no ticket content —
    /// only slicing logic.
    static func jsonPayload(from text: String?) -> String? {
        guard var trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("```") {
            if let firstNewline = trimmed.firstIndex(of: "\n") {
                trimmed = String(trimmed[trimmed.index(after: firstNewline)...])
            }
            if let closingFence = trimmed.range(of: "```", options: .backwards) {
                trimmed = String(trimmed[..<closingFence.lowerBound])
            }
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard trimmed.hasPrefix("{"), let start = trimmed.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var previous: Character = "\0"
        var index = start
        while index < trimmed.endIndex {
            let character = trimmed[index]
            if inString {
                if character == "\"" && previous != "\\" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(trimmed[start...index])
                }
            }
            previous = character
            index = trimmed.index(after: index)
        }
        return nil
    }
}
