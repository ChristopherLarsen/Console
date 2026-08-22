import XCTest
@testable import Console

final class BridgeProtocolTests: XCTestCase {

    private let sessionID = UUID()
    private let token = "abcdef1234567890abcdef1234567890"

    private func envelope(
        kind: BridgeProtocol.MessageKind,
        token: String = "abcdef1234567890abcdef1234567890",
        eventID: String = "event-1",
        modify: (inout BridgeEnvelope) -> Void = { _ in }
    ) -> BridgeEnvelope {
        var e = BridgeEnvelope(sessionID: self.sessionID.uuidString, token: token, eventID: eventID, kind: kind)
        modify(&e)
        return e
    }

    // MARK: - Envelope decode

    func testRoundTripsLifecycleEnvelope() throws {
        var env = envelope(kind: .lifecycle)
        env.lifecycleEvent = .turnCompleted
        let decoded = try BridgeEnvelope.decode(from: env.encodedData())
        XCTAssertEqual(decoded.kind, .lifecycle)
        XCTAssertEqual(decoded.lifecycleEvent, .turnCompleted)
        XCTAssertEqual(decoded.sessionID, sessionID.uuidString)
    }

    func testRejectsWrongProtocolVersion() {
        let raw = try? envelope(kind: .cwd).encodedData()
        var text = String(data: (raw ?? Data()).dropLast(), encoding: .utf8)!
            .replacingOccurrences(of: "\"protocol_version\":1", with: "\"protocol_version\":99")
        text.append("\n")
        XCTAssertThrowsError(try BridgeEnvelope.decode(from: Data(text.utf8))) { error in
            XCTAssertEqual(error as? BridgeEnvelopeError, .unsupportedVersion(99))
        }
    }

    func testRejectsUnknownKind() throws {
        var data = try envelope(kind: .lifecycle).encodedData()
        let text = String(data: data.dropLast(), encoding: .utf8)!
            .replacingOccurrences(of: "\"kind\":\"lifecycle\"", with: "\"kind\":\"mystery\"")
            + "\n"
        data = Data(text.utf8)
        XCTAssertThrowsError(try BridgeEnvelope.decode(from: data))
    }

    func testRejectsMalformedJSON() {
        XCTAssertThrowsError(try BridgeEnvelope.decode(from: Data("{not json".utf8)))
    }

    func testRejectsOversizedEnvelope() {
        let huge = String(repeating: "x", count: BridgeProtocol.maxEnvelopeBytes + 64)
        XCTAssertThrowsError(try BridgeEnvelope.decode(from: Data(huge.utf8)))
    }

    func testRejectsControlCharactersInTextFields() throws {
        var env = envelope(kind: .attention)
        env.attentionCategory = .blocked
        env.attentionMessage = "bad\u{1F}message"
        XCTAssertThrowsError(try BridgeEnvelope.decode(from: env.encodedData())) { error in
            XCTAssertEqual(error as? BridgeEnvelopeError, .controlCharacters(field: "attentionMessage"))
        }
    }

    func testAttentionRequiresMessageForReportedCategories() throws {
        var env = envelope(kind: .attention)
        env.attentionCategory = .blocked
        env.attentionMessage = nil
        XCTAssertThrowsError(try BridgeEnvelope.decode(from: env.encodedData()))

        // permission needs no message
        var permission = envelope(kind: .attention)
        permission.attentionCategory = .permission
        permission.attentionMessage = nil
        XCTAssertNoThrow(try BridgeEnvelope.decode(from: permission.encodedData()))
    }

    func testArtifactURLMustBeHTTPSAndBounded() throws {
        var env = envelope(kind: .artifact)
        env.artifactKind = .jiraIssue
        env.artifactLabel = "ENG-1"
        env.artifactURL = "http://insecure.example.com"
        XCTAssertThrowsError(try BridgeEnvelope.decode(from: env.encodedData()))

        env.artifactURL = "https://secure.example.com/ok"
        XCTAssertNoThrow(try BridgeEnvelope.decode(from: env.encodedData()))

        env.artifactURL = String(repeating: "a", count: 3000)
        XCTAssertThrowsError(try BridgeEnvelope.decode(from: env.encodedData()))
    }

    func testCompletionSummaryTrimsAndBounds() throws {
        var env = envelope(kind: .completion)
        env.completionOutcome = .completed
        env.completionSummary = "  done  "
        XCTAssertEqual(try BridgeEnvelope.decode(from: env.encodedData()).completionSummary, "done")

        env.completionSummary = String(repeating: "s", count: 401)
        XCTAssertThrowsError(try BridgeEnvelope.decode(from: env.encodedData()))
    }

    func testEventIDRestrictedToSafeCharset() throws {
        var env = envelope(kind: .lifecycle, eventID: "has space")
        env.lifecycleEvent = .sessionStarted
        XCTAssertThrowsError(try BridgeEnvelope.decode(from: env.encodedData()))
    }

    // MARK: - Router validation and idempotency

    @MainActor
    func testRouterValidatesSessionTokenAndDeduplicates() throws {
        let knownID = UUID()
        let tokens: [UUID: String] = [knownID: "tok"]
        var applied: [(UUID, BridgeEnvelope)] = []
        let router = SessionEventRouter(
            apply: { applied.append(($0, $1)) },
            tokenForSession: { tokens[$0] }
        )

        func makeLine(_ token: String, _ session: UUID, eventID: String) -> Data? {
            var env = BridgeEnvelope(sessionID: session.uuidString, token: token, eventID: eventID, kind: .lifecycle)
            env.lifecycleEvent = .sessionStarted
            return try? env.encodedData()
        }

        router.receive(rawData: makeLine("wrong", knownID, eventID: "e1")!)
        XCTAssertTrue(applied.isEmpty, "invalid token is rejected")

        router.receive(rawData: makeLine("tok", UUID(), eventID: "e2")!)
        XCTAssertTrue(applied.isEmpty, "unknown session is rejected")

        router.receive(rawData: makeLine("tok", knownID, eventID: "e3")!)
        XCTAssertEqual(applied.count, 1)

        router.receive(rawData: makeLine("tok", knownID, eventID: "e3")!)
        XCTAssertEqual(applied.count, 1, "duplicate events are ignored")

        router.receive(rawData: makeLine("tok", knownID, eventID: "e4")!)
        XCTAssertEqual(applied.count, 2, "same-session routing continues")

        router.forget(sessionID: knownID)
        router.receive(rawData: makeLine("tok", knownID, eventID: "e3")!)
        XCTAssertEqual(applied.count, 3, "forgetting a session clears its dedupe window")
    }
}
