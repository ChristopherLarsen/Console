import Foundation

/// Routes validated bridge envelopes to their sessions, serially and
/// idempotently. Runs on the main actor.
@MainActor
final class SessionEventRouter {
    private let apply: @MainActor (UUID, BridgeEnvelope) -> Void
    private var knownSessionTokens: (UUID) -> String?
    private var appliedEventIDs = [UUID: Set<String>]()
    private static let maxTrackedEventsPerSession = 512

    init(
        apply: @escaping @MainActor (UUID, BridgeEnvelope) -> Void,
        tokenForSession: @escaping (UUID) -> String?
    ) {
        self.apply = apply
        self.knownSessionTokens = tokenForSession
    }

    /// Validates and applies one raw envelope line. Rejections are silent by
    /// design; nothing about content is logged.
    func receive(rawData: Data) {
        guard let envelope = try? BridgeEnvelope.decode(from: rawData) else { return }
        guard let sessionID = UUID(uuidString: envelope.sessionID),
              let expectedToken = knownSessionTokens(sessionID),
              constantTimeEquals(envelope.token, expectedToken) else {
            return
        }
        guard !hasApplied(eventID: envelope.eventID, sessionID: sessionID) else { return }
        remember(eventID: envelope.eventID, sessionID: sessionID)
        apply(sessionID, envelope)
    }

    func forget(sessionID: UUID) {
        appliedEventIDs.removeValue(forKey: sessionID)
    }

    private func hasApplied(eventID: String, sessionID: UUID) -> Bool {
        appliedEventIDs[sessionID]?.contains(eventID) ?? false
    }

    private func remember(eventID: String, sessionID: UUID) {
        var set = appliedEventIDs[sessionID] ?? []
        if set.count >= Self.maxTrackedEventsPerSession {
            set.removeFirst()
        }
        set.insert(eventID)
        appliedEventIDs[sessionID] = set
    }

    private func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        var difference = a.count ^ b.count
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? Int(a[index]) : 0
            let right = index < b.count ? Int(b[index]) : 0
            difference |= left ^ right
        }
        return difference == 0
    }
}
