import XCTest
@testable import Console

@MainActor
final class MRResponsePrepFetcherTests: XCTestCase {
    private final class RecordingRunner: ProcessRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        var calls: [[String]] { lock.withLock { _calls } }
        /// Checked in order; the first endpoint fragment that matches answers.
        let responses: KeyValuePairs<String, String>

        init(responses: KeyValuePairs<String, String>) { self.responses = responses }

        func run(executablePath: String, arguments: [String], workingDirectory: String?, deadline: Date?) async throws -> ProcessResult {
            lock.withLock { _calls.append(arguments) }
            let endpoint = arguments.last ?? ""
            let match = responses.first { endpoint.contains($0.key) }?.value
            return ProcessResult(exitCode: match == nil ? 1 : 0, standardOutput: match ?? "", standardError: "")
        }
    }

    private func item() throws -> AuthoredMRAttention {
        let data = """
        {"project":"group/sub/app","iid":42,"url":"https://gitlab.example.test:8443/group/sub/app/-/merge_requests/42",
         "title":"Change","authorUsername":"me","state":"opened","unresolvedDiscussionCount":1,
         "externalApprovalCount":0,"approvalRulesSatisfied":false,"jiraIssueKey":null}
        """
        return try JSONDecoder().decode(AuthoredMRAttention.self, from: Data(data.utf8))
    }

    private let discussions = """
    [{"id":"a","notes":[{"system":true,"body":"assigned"}]},
     {"id":"b","notes":[{"resolvable":true,"resolved":false,"body":"Please rename this"}]},
     {"id":"c","notes":[{"resolvable":true,"resolved":true,"body":"done"}]}]
    """

    func testUnresolvedDiscussionsMatchTheScanDefinition() throws {
        let unresolved = try MRResponsePrepFetcher.unresolvedDiscussions(in: Data(discussions.utf8))
        XCTAssertEqual(unresolved.compactMap { $0["id"] as? String }, ["b"])
    }

    func testFetchUsesOnlyReadOnlyGlabCallsAndWritesEvidence() async throws {
        let runner = RecordingRunner(responses: [
            "/discussions": discussions, "/diffs": "[]", "merge_requests/42": #"{"iid":42}"#,
        ])
        let fetcher = MRResponsePrepFetcher(runner: runner, executableProvider: { "/usr/bin/false" })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("prep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let count = try await fetcher.fetch(try item(), into: directory)

        XCTAssertEqual(count, 1)
        XCTAssertEqual(runner.calls.count, 3)
        for call in runner.calls {
            XCTAssertEqual(Array(call.prefix(5)), ["api", "--method", "GET", "--hostname", "gitlab.example.test:8443"])
            XCTAssertTrue(call.last?.hasPrefix("projects/group%2Fsub%2Fapp/merge_requests/42") == true)
        }
        for name in [MRResponsePrepFetcher.instructionsFileName, MRResponsePrepFetcher.mergeRequestFileName,
                     MRResponsePrepFetcher.discussionsFileName, MRResponsePrepFetcher.diffsFileName] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path), name)
        }
    }

    func testFailedDiscussionsStopThePrep() async throws {
        let runner = RecordingRunner(responses: ["merge_requests/42": "{}"])
        let fetcher = MRResponsePrepFetcher(runner: runner, executableProvider: { "/usr/bin/false" })
        do {
            _ = try await fetcher.fetch(try item(), into: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
            XCTFail("expected failure")
        } catch let error as MRResponsePrepFetcher.FetchError {
            XCTAssertEqual(error, .malformedResponse("discussions"))
        }
    }

    func testPromptCarriesOnlyConsoleValues() throws {
        let mr = try item()
        let prompt = MRResponsePrepFetcher.prompt(for: mr, directory: URL(fileURLWithPath: "/tmp/prep"))
        XCTAssertFalse(prompt.contains("\n"))
        XCTAssertTrue(prompt.contains("!42"))
        XCTAssertTrue(prompt.contains("/tmp/prep/INSTRUCTIONS.md"))
        XCTAssertFalse(prompt.contains(mr.title))
    }

    func testDirectoryNameIsSanitizedPerMergeRequest() throws {
        let url = MRResponsePrepFetcher.directory(for: try item(), root: URL(fileURLWithPath: "/root"))
        XCTAssertEqual(url.lastPathComponent, "gitlab.example.test_8443_group_sub_app_42")
    }
}
