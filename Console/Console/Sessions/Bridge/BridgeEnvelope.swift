import Foundation

/// Wire protocol shared by Console and the embedded `ConsoleTermBridge` helper.
/// Newline-delimited Codable JSON with an 8 KiB maximum envelope.
enum BridgeProtocol {
    static let currentVersion = 1
    static let maxEnvelopeBytes = 8 * 1024
    static let maxMessageLength = 400
    static let maxAttentionMessageLength = 240
    static let maxArtifactLabelLength = 80
    static let maxURLLength = 2048

    enum MessageKind: String, Codable, Sendable, CaseIterable {
        case lifecycle
        case attention
        case artifact
        case completion
        case cwd
    }

    /// Reduced lifecycle events (post hook filtering). Raw hook event names
    /// never cross the bridge.
    enum LifecycleEventKind: String, Codable, Sendable, CaseIterable {
        case sessionStarted = "session_started"
        case promptSubmitted = "prompt_submitted"
        case turnCompleted = "turn_completed"
        case turnFailed = "turn_failed"
        case sessionEnded = "session_ended"
    }
}

enum BridgeEnvelopeError: Error, Equatable, Sendable {
    case malformedJSON
    case unsupportedVersion(Int)
    case unknownKind(String)
    case invalidEnum(field: String)
    case oversized
    case controlCharacters(field: String)
    case missingField(String)
    case urlTooLong
    case urlNotHTTPS
}

/// One validated message on the bridge socket.
struct BridgeEnvelope: Equatable, Sendable {
    var protocolVersion: Int = BridgeProtocol.currentVersion
    var sessionID: String
    var token: String
    var eventID: String
    var kind: BridgeProtocol.MessageKind
    var lifecycleEvent: BridgeProtocol.LifecycleEventKind?
    var attentionCategory: BridgeAttentionCategory?
    var attentionMessage: String?
    var artifactKind: SessionArtifactKind?
    var artifactLabel: String?
    var artifactURL: String?
    var completionOutcome: BridgeCompletionOutcome?
    var completionSummary: String?
    var cwdDirectory: String?
}

extension BridgeEnvelope {
    /// Encodes using the same snake_case field names the helper produces.
    func encodedData() throws -> Data {
        var container = [String: Any]()
        container["protocol_version"] = protocolVersion
        container["session_id"] = sessionID
        container["token"] = token
        container["event_id"] = eventID
        container["kind"] = kind.rawValue
        if let lifecycleEvent { container["lifecycle_event"] = lifecycleEvent.rawValue }
        if let attentionCategory { container["attention_category"] = attentionCategory.rawValue }
        if let attentionMessage { container["attention_message"] = attentionMessage }
        if let artifactKind { container["artifact_kind"] = artifactKind.rawValue }
        if let artifactLabel { container["artifact_label"] = artifactLabel }
        if let artifactURL { container["artifact_url"] = artifactURL }
        if let completionOutcome { container["completion_outcome"] = completionOutcome.rawValue }
        if let completionSummary { container["completion_summary"] = completionSummary }
        if let cwdDirectory { container["cwd_directory"] = cwdDirectory }
        guard JSONSerialization.isValidJSONObject(container),
              var data = try? JSONSerialization.data(withJSONObject: container, options: [.sortedKeys]) else {
            throw BridgeEnvelopeError.malformedJSON
        }
        data.append(UInt8(ascii: "\n"))
        return data
    }

    /// Decodes and validates one raw envelope. Only the fields Console needs
    /// are decoded; everything else in the payload is discarded immediately.
    static func decode(from data: Data) throws -> BridgeEnvelope {
        guard data.count <= BridgeProtocol.maxEnvelopeBytes else {
            throw BridgeEnvelopeError.oversized
        }
        guard let raw = try? JSONDecoder().decode(RawEnvelope.self, from: data) else {
            throw BridgeEnvelopeError.malformedJSON
        }
        guard raw.protocolVersion == BridgeProtocol.currentVersion else {
            throw BridgeEnvelopeError.unsupportedVersion(raw.protocolVersion)
        }
        guard let kind = BridgeProtocol.MessageKind(rawValue: raw.kind) else {
            throw BridgeEnvelopeError.unknownKind(raw.kind)
        }
        guard !raw.sessionID.isEmpty, !raw.token.isEmpty, !raw.eventID.isEmpty else {
            throw BridgeEnvelopeError.missingField("sessionID/token/eventID")
        }
        try validateIdentifier(raw.eventID, field: "eventID")
        try validateIdentifier(raw.sessionID, field: "sessionID")

        var envelope = BridgeEnvelope(
            sessionID: raw.sessionID,
            token: raw.token,
            eventID: raw.eventID,
            kind: kind
        )

        switch kind {
        case .lifecycle:
            guard let event = raw.lifecycleEvent else {
                throw BridgeEnvelopeError.invalidEnum(field: "lifecycleEvent")
            }
            envelope.lifecycleEvent = event
        case .attention:
            guard let category = raw.attentionCategory else {
                throw BridgeEnvelopeError.invalidEnum(field: "attentionCategory")
            }
            envelope.attentionCategory = category
            if let message = raw.attentionMessage {
                try validateText(message, maxLength: BridgeProtocol.maxAttentionMessageLength, field: "attentionMessage")
                envelope.attentionMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if category != .permission && category != .question {
                throw BridgeEnvelopeError.missingField("attentionMessage")
            }
        case .artifact:
            guard let artifactKind = raw.artifactKind else {
                throw BridgeEnvelopeError.invalidEnum(field: "artifactKind")
            }
            guard let label = raw.artifactLabel else {
                throw BridgeEnvelopeError.missingField("artifactLabel")
            }
            try validateText(label, maxLength: BridgeProtocol.maxArtifactLabelLength, field: "artifactLabel")
            envelope.artifactKind = artifactKind
            envelope.artifactLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
            if let urlString = raw.artifactURL, !urlString.isEmpty {
                guard urlString.count <= BridgeProtocol.maxURLLength else {
                    throw BridgeEnvelopeError.urlTooLong
                }
                guard let url = URL(string: urlString), url.scheme?.lowercased() == "https" else {
                    throw BridgeEnvelopeError.urlNotHTTPS
                }
                envelope.artifactURL = urlString
            }
        case .completion:
            guard let outcome = raw.completionOutcome else {
                throw BridgeEnvelopeError.invalidEnum(field: "completionOutcome")
            }
            guard let summary = raw.completionSummary else {
                throw BridgeEnvelopeError.missingField("completionSummary")
            }
            try validateText(summary, maxLength: BridgeProtocol.maxMessageLength, field: "completionSummary")
            envelope.completionOutcome = outcome
            envelope.completionSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        case .cwd:
            guard let directory = raw.cwdDirectory else {
                throw BridgeEnvelopeError.missingField("cwdDirectory")
            }
            try validateText(directory, maxLength: 4096, field: "cwdDirectory")
            envelope.cwdDirectory = directory
        }
        return envelope
    }

    private static func validateIdentifier(_ value: String, field: String) throws {
        // Identifiers are opaque tokens; restrict to a safe charset and size.
        guard value.count <= 128 else { throw BridgeEnvelopeError.oversized }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw BridgeEnvelopeError.controlCharacters(field: field)
        }
    }

    private static func validateText(_ text: String, maxLength: Int, field: String) throws {
        guard text.count <= maxLength else {
            throw BridgeEnvelopeError.oversized
        }
        for scalar in text.unicodeScalars where containsForbiddenScalar(scalar) {
            throw BridgeEnvelopeError.controlCharacters(field: field)
        }
    }

    private static func containsForbiddenScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isDefaultIgnorableCodePoint {
            return true
        }
        switch scalar.value {
        case 0x00...0x08, 0x0B...0x0C, 0x0E...0x1F, 0x7F...0x9F:
            return true
        default:
            return false
        }
    }
}

private struct RawEnvelope: Decodable {
    var protocolVersion: Int
    var sessionID: String
    var token: String
    var eventID: String
    var kind: String
    var lifecycleEvent: BridgeProtocol.LifecycleEventKind?
    var attentionCategory: BridgeAttentionCategory?
    var attentionMessage: String?
    var artifactKind: SessionArtifactKind?
    var artifactLabel: String?
    var artifactURL: String?
    var completionOutcome: BridgeCompletionOutcome?
    var completionSummary: String?
    var cwdDirectory: String?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case sessionID = "session_id"
        case token
        case eventID = "event_id"
        case kind
        case lifecycleEvent = "lifecycle_event"
        case attentionCategory = "attention_category"
        case attentionMessage = "attention_message"
        case artifactKind = "artifact_kind"
        case artifactLabel = "artifact_label"
        case artifactURL = "artifact_url"
        case completionOutcome = "completion_outcome"
        case completionSummary = "completion_summary"
        case cwdDirectory = "cwd_directory"
    }
}
