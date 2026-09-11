import XCTest
@testable import Console

@MainActor
final class SessionHistoryTests: XCTestCase {

    private var defaults: UserDefaults!
    private var fixtureRoot: URL!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "SessionHistoryTests-\(UUID().uuidString)")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-history-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fixtureRoot = root
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fixtureRoot!)
        super.tearDown()
    }

    private var historyRoot: URL {
        fixtureRoot.appendingPathComponent("projects", isDirectory: true)
    }

    /// Writes a transcript file for `sessionID` under a munged project dir
    /// and returns the file URL.
    @discardableResult
    private func writeTranscript(
        _ sessionID: UUID,
        lines: [String],
        projectMunge: String = "-Users-dev-Workspace-Demo"
    ) throws -> URL {
        let projectDir = historyRoot.appendingPathComponent(projectMunge, isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let fileURL = projectDir.appendingPathComponent("\(sessionID.uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private func line(
        type: String,
        timestamp: String = "2026-09-10T10:00:00.000Z",
        cwd: String = "/Users/dev/Workspace/Demo",
        branch: String = "main",
        isSidechain: Bool = false,
        isMeta: Bool = false,
        title: String? = nil,
        summary: String? = nil,
        message: [String: Any]? = nil,
        extra: [String: Any] = [:]
    ) -> String {
        var object: [String: Any] = [
            "type": type,
            "timestamp": timestamp,
            "cwd": cwd,
            "gitBranch": branch,
            "isSidechain": isSidechain,
            "isMeta": isMeta,
        ]
        if let title { object["title"] = title }
        if let summary { object["summary"] = summary }
        if let message { object["message"] = message }
        for (key, value) in extra { object[key] = value }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private func userMessage(_ text: String) -> [String: Any] {
        ["role": "user", "content": text]
    }

    // MARK: - Transcript parsing

    func testTranscriptMetadataPrefersCustomTitleThenSummaryThenFirstUserMessage() throws {
        let fileURL = try writeTranscript(UUID(), lines: [
            line(
                type: "user", timestamp: "2026-09-10T09:00:30.000Z", isMeta: true,
                message: userMessage("<command-name>/clear</command-name>")
            ),
            line(
                type: "summary", timestamp: "2026-09-10T09:00:00.000Z",
                summary: "Auto summary of the conversation"
            ),
            line(
                type: "assistant", timestamp: "2026-09-10T09:01:00.000Z",
                message: ["role": "assistant", "content": [["type": "text", "text": "Hello"]]]
            ),
            line(
                type: "user", timestamp: "2026-09-10T09:02:00.000Z",
                message: userMessage("First user prompt about the login bug")
            ),
            line(
                type: "user", timestamp: "2026-09-10T09:02:30.000Z", isSidechain: true,
                message: userMessage("subagent sidechain message")
            ),
            line(
                type: "user", timestamp: "2026-09-10T09:03:00.000Z",
                title: "Fix SCRUM-9 login redirect",
                message: userMessage("Later prompt should not become the title")
            ),
        ])

        let metadata = try XCTUnwrap(SessionHistoryReader.transcriptMetadata(at: fileURL))
        XCTAssertEqual(metadata.customTitle, "Fix SCRUM-9 login redirect")
        XCTAssertEqual(metadata.summary, "Auto summary of the conversation")
        XCTAssertEqual(metadata.firstUserMessage, "First user prompt about the login bug")
        XCTAssertEqual(metadata.lastCWD, "/Users/dev/Workspace/Demo")
        XCTAssertEqual(metadata.gitBranch, "main")
        XCTAssertEqual(
            metadata.lastTimestamp,
            try XCTUnwrap(SessionHistoryReader.decodeTimestamp("2026-09-10T09:03:00.000Z"))
        )
        XCTAssertTrue(metadata.hasMainConversation)
    }

    func testSubagentOnlyTranscriptsAreExcluded() throws {
        let fileURL = try writeTranscript(UUID(), lines: [
            line(type: "user", isSidechain: true, message: userMessage("sidechain only")),
            line(
                type: "assistant", isSidechain: true,
                message: ["role": "assistant", "content": [["type": "text", "text": "sidechain"]]]
            ),
        ])

        XCTAssertNil(
            SessionHistoryReader.transcriptMetadata(at: fileURL),
            "subagent-only transcripts are not resumable conversations"
        )
    }

    func testMalformedLinesAreSkippedAndValidLinesStillApplied() throws {
        let fileURL = try writeTranscript(UUID(), lines: [
            "not json at all",
            "{\"type\": \"user\", \"message\": {\"role\": \"user\"",
            line(
                type: "user", timestamp: "2026-09-10T08:00:00.000Z",
                cwd: "/Users/dev/Workspace/Other",
                branch: "feature/other",
                message: userMessage("prompt after garbage")
            ),
        ])

        let metadata = try XCTUnwrap(SessionHistoryReader.transcriptMetadata(at: fileURL))
        XCTAssertEqual(metadata.firstUserMessage, "prompt after garbage")
        XCTAssertEqual(metadata.lastCWD, "/Users/dev/Workspace/Other")
        XCTAssertEqual(metadata.gitBranch, "feature/other")
    }

    func testFirstUserMessageReadsTextBlocksAndSkipsToolResults() {
        let toolResult = SessionHistoryReader.userMessageText(from: [
            "role": "user",
            "content": [["type": "tool_result", "content": "command output"]],
        ])
        XCTAssertNil(toolResult)

        let textBlocks = SessionHistoryReader.userMessageText(from: [
            "role": "user",
            "content": [
                ["type": "text", "text": "line one\nline two"],
                ["type": "text", "text": "line three"],
            ],
        ])
        XCTAssertEqual(textBlocks, "line one line two line three")
    }

    func testTimestampDecodingHandlesFractionalAndPlainSeconds() {
        let fractional = SessionHistoryReader.decodeTimestamp("2026-09-10T10:00:00.123Z")
        let plain = SessionHistoryReader.decodeTimestamp("2026-09-10T10:00:00Z")
        XCTAssertNotNil(fractional)
        XCTAssertNotNil(plain)
        XCTAssertEqual(fractional?.timeIntervalSince1970 ?? 0, plain!.timeIntervalSince1970 + 0.123, accuracy: 0.01)
    }

    // MARK: - Scan, filtering inputs, and classification

    func testScanBuildsRecordsSortedByLastActiveAndClassifiesTickets() async throws {
        let mainID = UUID()
        let sidechainID = UUID()
        let oldID = UUID()
        let demoDirectory = fixtureRoot.appendingPathComponent("Demo", isDirectory: true)
        try FileManager.default.createDirectory(at: demoDirectory, withIntermediateDirectories: true)

        try writeTranscript(mainID, lines: [
            line(
                type: "user", timestamp: "2026-09-10T12:00:00.000Z",
                cwd: demoDirectory.path,
                message: userMessage("latest session")
            ),
        ])
        try writeTranscript(sidechainID, lines: [
            line(type: "user", timestamp: "2026-09-10T13:00:00.000Z", isSidechain: true, message: userMessage("subagent")),
        ], projectMunge: "-Users-dev-Workspace-Other")
        try writeTranscript(oldID, lines: [
            line(
                type: "user", timestamp: "2026-09-08T08:00:00.000Z",
                cwd: demoDirectory.path,
                title: "SCRUM-9 sprint cleanup",
                message: userMessage("older ticket session")
            ),
        ], projectMunge: "-Users-dev-Workspace-Other")

        let associations = [oldID: "SCRUM-9"]
        let root = historyRoot
        let (records, _) = await Task.detached {
            SessionHistoryReader.scan(root: root, associations: associations, cache: [:])
        }.value

        // Subagent-only transcript is excluded; most recent first.
        XCTAssertEqual(records.map(\.claudeSessionID), [mainID, oldID])

        let old = try XCTUnwrap(records.first { $0.claudeSessionID == oldID })
        XCTAssertEqual(old.title, "SCRUM-9 sprint cleanup")
        XCTAssertEqual(old.ticketKey, "SCRUM-9")
        XCTAssertTrue(old.isTicketSession)
        XCTAssertFalse(old.isWorkingDirectoryMissing)
        if let main = records.first(where: { $0.claudeSessionID == mainID }) {
            XCTAssertNil(main.ticketKey, "no custom title or association: stays a general session")
            XCTAssertFalse(main.isTicketSession)
        } else {
            XCTFail("main transcript missing from scan results")
        }
    }

    func testScanFlagsMissingWorkingDirectories() async throws {
        let goneID = UUID()
        try writeTranscript(goneID, lines: [
            line(
                type: "user", timestamp: "2026-09-10T12:00:00.000Z",
                cwd: fixtureRoot.appendingPathComponent("vanished", isDirectory: true).path,
                message: userMessage("folder is gone")
            ),
        ])

        let root = historyRoot
        let (records, _) = await Task.detached {
            SessionHistoryReader.scan(root: root, associations: [:], cache: [:])
        }.value
        let record = try XCTUnwrap(records.first)
        XCTAssertTrue(record.isWorkingDirectoryMissing)
    }

    func testScanReusesCachedRecordsForUnchangedFiles() async throws {
        let id = UUID()
        let fileURL = try writeTranscript(id, lines: [
            line(type: "user", timestamp: "2026-09-10T12:00:00.000Z", message: userMessage("fresh scan")),
        ])

        let root = historyRoot
        let (firstRecords, cache) = await Task.detached {
            SessionHistoryReader.scan(root: root, associations: [:], cache: [:])
        }.value
        let cacheKey = fileURL.resolvingSymlinksInPath().path
        guard let scannedEntry = cache[cacheKey] else {
            XCTFail(
                "cache missing entry for \(cacheKey); keys=\(cache.keys.sorted()) "
                + "records=\(firstRecords.map(\.claudeSessionID.uuidString))"
            )
            return
        }
        let scanned = scannedEntry.record

        // A cache entry with matching size + modification date is reused
        // verbatim, even though the stub title differs from disk.
        let stale = SessionHistoryRecord(
            claudeSessionID: id,
            title: "CACHED",
            lastActive: scanned.lastActive,
            workingDirectory: scanned.workingDirectory,
            gitBranch: nil,
            transcriptByteCount: scanned.transcriptByteCount,
            ticketKey: nil,
            isWorkingDirectoryMissing: false
        )
        let (second, _) = await Task.detached {
            SessionHistoryReader.scan(
                root: root, associations: [:],
                cache: [fileURL.resolvingSymlinksInPath().path: SessionHistoryReader.CachedMetadata(
                    byteCount: scanned.transcriptByteCount,
                    modified: try! FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as! Date,
                    record: stale
                )]
            )
        }.value
        XCTAssertEqual(try XCTUnwrap(second.first), stale, "unchanged size+mtime reuses the cached record")
    }

    func testTicketClassificationRules() {
        // Association wins over everything.
        XCTAssertEqual(
            SessionTicketClassification.ticketKey(savedAssociation: "NMA-42", title: "Fix login", isCustomTitle: true),
            "NMA-42"
        )
        // Ticket-style custom titles are recognized.
        XCTAssertEqual(
            SessionTicketClassification.ticketKey(savedAssociation: nil, title: "SCRUM-9 sprint cleanup", isCustomTitle: true),
            "SCRUM-9"
        )
        XCTAssertEqual(
            SessionTicketClassification.ticketKey(savedAssociation: nil, title: "S-1234", isCustomTitle: true),
            "S-1234"
        )
        // A ticket mentioned in a summary or first message never classifies.
        XCTAssertNil(
            SessionTicketClassification.ticketKey(
                savedAssociation: nil, title: "Add NMA-1234 to the board", isCustomTitle: false
            )
        )
        XCTAssertNil(
            SessionTicketClassification.ticketKey(savedAssociation: nil, title: "Fix login", isCustomTitle: true)
        )
        // Lowercase keys are not ticket-styled.
        XCTAssertNil(
            SessionTicketClassification.ticketKey(savedAssociation: nil, title: "fix scrum-9 now", isCustomTitle: true)
        )
        XCTAssertTrue(SessionTicketClassification.consoleStoryName("S-1234"))
        XCTAssertFalse(SessionTicketClassification.consoleStoryName("S-12x4"))
    }

    // MARK: - Formatting

    func testTranscriptSizeAndRelativeTimeFormatting() {
        XCTAssertTrue(SessionHistoryFormatting.transcriptSize(12_400).hasSuffix("KB"))
        XCTAssertTrue(SessionHistoryFormatting.transcriptSize(1_500_000).hasSuffix("MB"))
        XCTAssertFalse(SessionHistoryFormatting.relativeLastActive(Date()).isEmpty)
        XCTAssertFalse(SessionHistoryFormatting.exactLastActive(Date()).isEmpty)
    }

    // MARK: - Associations

    func testTicketAssociationsRoundTrip() {
        let associations = SessionTicketAssociations(defaults: defaults)
        let id = UUID()
        XCTAssertNil(associations.key(for: id))
        associations.associate("ENG-7", with: id)
        XCTAssertEqual(associations.key(for: id), "ENG-7")
        XCTAssertEqual(associations.allKeys(), [id: "ENG-7"])
        // Empty keys are never stored.
        let other = UUID()
        associations.associate("   ", with: other)
        XCTAssertNil(associations.key(for: other))
    }
}
