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

    func testWhitespaceOnlyRequiredStringsAreRejected() throws {
        var attention = envelope(kind: .attention)
        attention.attentionCategory = .blocked
        attention.attentionMessage = "   "
        XCTAssertThrowsError(try BridgeEnvelope.decode(from: attention.encodedData()))

        var artifact = envelope(kind: .artifact)
        artifact.artifactKind = .jiraIssue
        artifact.artifactLabel = " \n\t "
        XCTAssertThrowsError(try BridgeEnvelope.decode(from: artifact.encodedData()))

        var completion = envelope(kind: .completion)
        completion.completionOutcome = .completed
        completion.completionSummary = "   "
        XCTAssertThrowsError(try BridgeEnvelope.decode(from: completion.encodedData()))
    }

    func testArtifactURLRejectsControlCharacters() throws {
        var env = envelope(kind: .artifact)
        env.artifactKind = .gitlabMergeRequest
        env.artifactLabel = "MR !1"
        env.artifactURL = "https://fixture.example.test/a\u{1F}b"
        XCTAssertThrowsError(try BridgeEnvelope.decode(from: env.encodedData())) { error in
            XCTAssertEqual(error as? BridgeEnvelopeError, .controlCharacters(field: "artifactURL"))
        }
    }

    func testLineBudgetKeepsTheTrailingNewlineInsideThe8KiBContract() {
        XCTAssertEqual(
            SessionBridgeSocketServer.maxLineBytes,
            BridgeProtocol.maxEnvelopeBytes - 1,
            "a line body plus its newline must fit in 8 KiB"
        )
    }

    func testSocketInodeIsCreatedWithMode0700() throws {
        guard let socketURL = SessionBridgeSocketServer.makeProtectedSocketURL() else {
            XCTFail("no protected socket location available")
            return
        }
        let server = SessionBridgeSocketServer(socketPath: socketURL.path) { _ in }
        guard server.start() else {
            XCTFail("socket listener failed to start")
            return
        }
        defer { server.stop() }

        let attributes = try FileManager.default.attributesOfItem(atPath: socketURL.path)
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.uint16Value,
            0o700,
            "the socket inode itself is 0700, not just its directory"
        )
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

    @MainActor
    func testIdempotencyWindowEvictsOldestEventFirst() {
        let knownID = UUID()
        let tokens: [UUID: String] = [knownID: "tok"]
        var applied: [String] = []
        let router = SessionEventRouter(
            apply: { _, envelope in applied.append(envelope.eventID) },
            tokenForSession: { tokens[$0] }
        )

        func line(_ eventID: String) -> Data? {
            var env = BridgeEnvelope(sessionID: knownID.uuidString, token: "tok", eventID: eventID, kind: .lifecycle)
            env.lifecycleEvent = .promptSubmitted
            return try? env.encodedData()
        }

        let windowSize = 512
        for index in 0..<windowSize {
            router.receive(rawData: line("evt-\(index)")!)
        }
        XCTAssertEqual(applied.count, windowSize)

        // A new event evicts the oldest id first-in-first-out.
        router.receive(rawData: line("evt-\(windowSize)")!)
        XCTAssertEqual(applied.count, windowSize + 1)

        // Every still-tracked id stays ignored, including the newest.
        router.receive(rawData: line("evt-\(windowSize)")!)
        router.receive(rawData: line("evt-1")!)
        XCTAssertEqual(applied.count, windowSize + 1, "duplicates inside the window are ignored")

        // The evicted id is exactly the oldest one, so it re-applies.
        router.receive(rawData: line("evt-0")!)
        XCTAssertEqual(applied.count, windowSize + 2, "the evicted id is exactly the oldest one")
    }
}
