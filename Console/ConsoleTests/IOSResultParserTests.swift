import XCTest
@testable import Console

final class IOSResultParserTests: XCTestCase {

    private var tmpRoot: URL!
    private var runner: FakeXcresultProcessRunner!
    private var parser: IOSResultParser!

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 10
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-result-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        runner = FakeXcresultProcessRunner()
        parser = IOSResultParser(processRunner: runner)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
        parser = nil
        runner = nil
    }

    // MARK: - Argv

    func testXcresulttoolArgvIsGetOnlyAndNeverExports() {
        let bundle = URL(fileURLWithPath: "/tmp/Job.xcresult")
        let queries: [IOSXcresulttoolCommand.Query] = [
            .contentAvailability, .buildResults, .testSummary, .tests
        ]
        for query in queries {
            let spec = IOSXcresulttoolCommand.makeLaunchSpec(query: query, bundleURL: bundle)
            XCTAssertEqual(spec.executablePath, "/usr/bin/xcrun")
            XCTAssertEqual(spec.arguments.first, "xcresulttool")
            XCTAssertEqual(spec.arguments[1], "get")
            XCTAssertEqual(value(after: "--path", in: spec.arguments), bundle.path)
            XCTAssertTrue(spec.arguments.contains("--compact"))
            XCTAssertFalse(spec.arguments.contains("export"))
            XCTAssertFalse(spec.arguments.contains("merge"))
            XCTAssertFalse(spec.arguments.contains("-exportArchive"))
            XCTAssertNil(spec.workingDirectory)
        }

        let tests = IOSXcresulttoolCommand.makeLaunchSpec(query: .testSummary, bundleURL: bundle)
        XCTAssertTrue(tests.arguments.contains("test-results"))
        XCTAssertTrue(tests.arguments.contains("summary"))
    }

    // MARK: - Successful build

    func testSuccessfulBuildParsesEmptyErrorsAndDoesNotInferFromLogWording() async throws {
        let bundle = try plantBundle()
        runner.availabilityJSON = Self.noTestsAvailabilityJSON
        runner.buildJSON = """
        preamble: BUILD FAILED and tests exploded
        \(Self.successfulBuildJSON)
        """
        let summary = await parser.parseBundle(at: bundle, jobKind: .build)

        XCTAssertEqual(summary.parseStatus, .parsed)
        XCTAssertEqual(summary.outcome, .succeeded)
        XCTAssertFalse(summary.recordsIndicateFailure)
        XCTAssertEqual(summary.errorCount, 0)
        XCTAssertTrue(summary.issues.isEmpty)
        XCTAssertEqual(runner.queryNames, ["content-availability", "build-results"])
        XCTAssertFalse(runner.invocations.contains { $0.arguments.contains("export") })
        XCTAssertFalse(runner.invocations.contains { $0.arguments.contains("summary") })
    }

    // MARK: - Compile failure

    func testCompileFailureExtractsFileURLLineAndMessage() async throws {
        let bundle = try plantBundle()
        runner.availabilityJSON = Self.noTestsAvailabilityJSON
        runner.buildJSON = Self.compileFailureJSON
        let summary = await parser.parseBundle(at: bundle, jobKind: .build)

        XCTAssertEqual(summary.parseStatus, .parsed)
        XCTAssertEqual(summary.outcome, .failed)
        XCTAssertTrue(summary.recordsIndicateFailure)
        XCTAssertEqual(summary.errorCount, 1)
        let issue = try XCTUnwrap(summary.issues.first)
        XCTAssertEqual(issue.kind, .buildError)
        XCTAssertEqual(issue.message, "Cannot find 'Foo' in scope")
        XCTAssertEqual(issue.fileURL?.path, "/tmp/App/ContentView.swift")
        XCTAssertEqual(issue.line, 17)
        XCTAssertNil(issue.testIdentifier)
    }

    func testBuildSucceededWordingDoesNotHideStructuredErrors() async throws {
        let bundle = try plantBundle()
        runner.availabilityJSON = Self.noTestsAvailabilityJSON
        runner.buildJSON = Self.buildJSONWithSucceededMessageAndError
        let summary = await parser.parseBundle(at: bundle, jobKind: .build)

        XCTAssertEqual(summary.outcome, .failed)
        XCTAssertTrue(summary.recordsIndicateFailure)
        XCTAssertEqual(summary.issues.first?.message, "BUILD SUCCEEDED")
    }

    // MARK: - Failing selected test

    func testFailingSelectedTestExtractsIdentifierMessageAndSourceLocation() async throws {
        let bundle = try plantBundle()
        runner.availabilityJSON = Self.testsAvailabilityJSON
        runner.buildJSON = Self.successfulBuildJSON
        runner.testSummaryJSON = Self.failingTestSummaryJSON
        runner.testsJSON = Self.failingTestsTreeJSON
        let summary = await parser.parseBundle(at: bundle, jobKind: .runSelectedTests)

        XCTAssertEqual(summary.parseStatus, .parsed)
        XCTAssertEqual(summary.outcome, .failed)
        XCTAssertTrue(summary.recordsIndicateFailure)
        XCTAssertEqual(summary.failedTestCount, 1)
        let issue = try XCTUnwrap(summary.issues.first { $0.kind == .testFailure })
        XCTAssertEqual(issue.testIdentifier, "AppTests/LoginTests/testLogin")
        XCTAssertEqual(issue.message, "XCTAssertEqual failed: (\"a\") is not equal to (\"b\")")
        XCTAssertEqual(issue.fileURL?.path, "/tmp/App/LoginTests.swift")
        XCTAssertEqual(issue.line, 42)
        XCTAssertTrue(runner.queryNames.contains("test-results-summary"))
        XCTAssertTrue(runner.queryNames.contains("test-results-tests"))
    }

    func testTestFailuresMayBeASingleObject() async throws {
        let bundle = try plantBundle()
        runner.availabilityJSON = Self.testsAvailabilityJSON
        runner.buildJSON = Self.successfulBuildJSON
        runner.testSummaryJSON = Self.singleObjectFailureSummaryJSON
        let summary = await parser.parseBundle(at: bundle, jobKind: .runSelectedTests)

        XCTAssertEqual(summary.failedTestCount, 1)
        XCTAssertEqual(summary.issues.first?.testIdentifier, "AppTests/LoginTests/testLogin")
        XCTAssertEqual(summary.issues.first?.message, "failed")
    }

    func testURLOnlyFailureIdentifierMergesSourceLocation() async throws {
        let bundle = try plantBundle()
        runner.availabilityJSON = Self.testsAvailabilityJSON
        runner.buildJSON = Self.successfulBuildJSON
        runner.testSummaryJSON = Self.urlOnlyFailureSummaryJSON
        runner.testsJSON = Self.failingTestsTreeJSON
        let summary = await parser.parseBundle(at: bundle, jobKind: .runSelectedTests)

        let issue = try XCTUnwrap(summary.issues.first { $0.kind == .testFailure })
        XCTAssertEqual(issue.testIdentifier, "AppTests/LoginTests/testLogin")
        XCTAssertEqual(issue.fileURL?.path, "/tmp/App/LoginTests.swift")
        XCTAssertEqual(issue.line, 42)
    }

    func testNormalizedTestIdentifierMatchesURLAndSlashForms() {
        XCTAssertEqual(
            IOSResultParser.normalizedTestIdentifier("test://com.apple.xcode/AppTests/LoginTests/testLogin"),
            "AppTests/LoginTests/testLogin"
        )
        XCTAssertEqual(
            IOSResultParser.normalizedTestIdentifier("AppTests/LoginTests/testLogin"),
            "AppTests/LoginTests/testLogin"
        )
        XCTAssertNil(IOSResultParser.normalizedTestIdentifier("test://"))
        XCTAssertNil(IOSResultParser.normalizedTestIdentifier(nil))
    }

    func testPassedResultWithFailureWordingIsNotAFailure() async throws {
        let bundle = try plantBundle()
        runner.availabilityJSON = Self.testsAvailabilityJSON
        runner.buildJSON = Self.successfulBuildJSON
        runner.testSummaryJSON = Self.passedSummaryWithFailureWordingJSON
        let summary = await parser.parseBundle(at: bundle, jobKind: .runSelectedTests)

        XCTAssertEqual(summary.outcome, .succeeded)
        XCTAssertFalse(summary.recordsIndicateFailure)
        XCTAssertEqual(summary.failedTestCount, 0)
        XCTAssertTrue(summary.issues.isEmpty)
    }

    // MARK: - Missing / incomplete / corrupt / schema

    func testMissingBundleDoesNotCallXcresulttool() async {
        let missing = tmpRoot.appendingPathComponent("missing.xcresult")
        let summary = await parser.parseBundle(at: missing, jobKind: .build)

        XCTAssertEqual(summary.parseStatus, .missingBundle)
        XCTAssertEqual(summary.outcome, .unknown)
        XCTAssertFalse(summary.recordsIndicateFailure)
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testFileAtBundlePathIsCorruptNotSuccess() async throws {
        let fileURL = tmpRoot.appendingPathComponent("not-a-bundle.xcresult")
        try Data("{not-valid-xcresult".utf8).write(to: fileURL)
        let summary = await parser.parseBundle(at: fileURL, jobKind: .build)

        XCTAssertEqual(summary.parseStatus, .corruptBundle)
        XCTAssertFalse(summary.recordsIndicateFailure)
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testIncompleteBundleFromToolStderr() async throws {
        let bundle = try plantBundle()
        runner.availabilityResult = ProcessResult(
            exitCode: 1,
            standardOutput: "",
            standardError: "Error: The result bundle is incomplete."
        )
        let summary = await parser.parseBundle(at: bundle, jobKind: .runSelectedTests)

        XCTAssertEqual(summary.parseStatus, .incompleteBundle)
        XCTAssertFalse(summary.recordsIndicateFailure)
        XCTAssertEqual(summary.outcome, .unknown)
    }

    func testMalformedJSONIsSchemaMismatchAndNotSuccess() async throws {
        let bundle = try plantBundle()
        runner.availabilityJSON = Self.noTestsAvailabilityJSON
        runner.buildResult = ProcessResult(
            exitCode: 0,
            standardOutput: "{not-valid",
            standardError: ""
        )
        let summary = await parser.parseBundle(at: bundle, jobKind: .build)

        XCTAssertEqual(summary.parseStatus, .schemaMismatch)
        XCTAssertFalse(summary.recordsIndicateFailure)
        XCTAssertEqual(summary.outcome, .unknown)
    }

    func testUnrecognizedJSONObjectIsSchemaMismatch() async throws {
        let bundle = try plantBundle()
        runner.availabilityJSON = #"{"unrelated":true,"hasTestResults":false}"#
        runner.buildJSON = #"{"unrelated":true}"#
        let summary = await parser.parseBundle(at: bundle, jobKind: .build)

        XCTAssertEqual(summary.parseStatus, .schemaMismatch)
        XCTAssertFalse(summary.recordsIndicateFailure)
    }

    func testIssueCapIsBounded() async throws {
        let bundle = try plantBundle()
        runner.availabilityJSON = Self.noTestsAvailabilityJSON
        let errors = (1...40).map { index in
            """
            {"issueType":"error","message":"error \(index)","sourceURL":"file:///tmp/A.swift#StartingLineNumber=\(index)"}
            """
        }.joined(separator: ",")
        runner.buildJSON = """
        {
          "status": "failed",
          "errorCount": 40,
          "errors": [\(errors)],
          "warnings": [],
          "analyzerWarnings": []
        }
        """
        let summary = await parser.parseBundle(at: bundle, jobKind: .build)

        XCTAssertEqual(summary.errorCount, 40)
        XCTAssertEqual(summary.issues.count, IOSResultSummary.maxIssues)
        XCTAssertTrue(summary.recordsIndicateFailure)
    }

    // MARK: - Location parsing

    func testSourceLocationParsesFileURLFragmentAndColonPath() {
        let fromURL = IOSResultParser.sourceLocation(
            from: "file:///tmp/App/ContentView.swift#EndingLineNumber=17&StartingLineNumber=17"
        )
        XCTAssertEqual(fromURL.fileURL?.path, "/tmp/App/ContentView.swift")
        XCTAssertEqual(fromURL.line, 17)

        let fromPath = IOSResultParser.sourceLocation(from: "/tmp/App/LoginTests.swift:42:18")
        XCTAssertEqual(fromPath.fileURL?.path, "/tmp/App/LoginTests.swift")
        XCTAssertEqual(fromPath.line, 42)

        let empty = IOSResultParser.sourceLocation(from: "  ")
        XCTAssertNil(empty.fileURL)
        XCTAssertNil(empty.line)
    }

    func testResolvedStateNeverPromotesFailureOnParserError() {
        let missing = IOSResultSummary.unparsed(.missingBundle, message: "missing")
        XCTAssertEqual(
            IOSBuildJob.resolvedState(processState: .failed, resultSummary: missing),
            .failed
        )
        XCTAssertEqual(
            IOSBuildJob.resolvedState(processState: .succeeded, resultSummary: missing),
            .succeeded
        )
        XCTAssertEqual(
            IOSBuildJob.resolvedState(processState: .cancelled, resultSummary: missing),
            .cancelled
        )
        XCTAssertEqual(
            IOSBuildJob.resolvedState(processState: .timedOut, resultSummary: missing),
            .timedOut
        )

        let recordsFailed = IOSResultSummary.parsed(
            outcome: .failed,
            issues: [
                IOSResultIssue(kind: .testFailure, message: "boom", fileURL: nil, line: nil, testIdentifier: "A/B/c")
            ]
        )
        XCTAssertEqual(
            IOSBuildJob.resolvedState(processState: .succeeded, resultSummary: recordsFailed),
            .failed
        )
        XCTAssertEqual(
            IOSBuildJob.resolvedState(processState: .failed, resultSummary: recordsFailed),
            .failed
        )
    }

    // MARK: - Helpers

    private func plantBundle() throws -> URL {
        let url = tmpRoot.appendingPathComponent("\(UUID().uuidString).xcresult", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    private static let noTestsAvailabilityJSON = """
    {"hasCoverage":false,"hasDiagnostics":false,"hasTestResults":false,"logs":[]}
    """

    private static let testsAvailabilityJSON = """
    {"hasCoverage":false,"hasDiagnostics":false,"hasTestResults":true,"logs":[]}
    """

    private static let successfulBuildJSON = """
    {
      "actionTitle": "Build App",
      "status": "succeeded",
      "errorCount": 0,
      "warningCount": 0,
      "analyzerWarningCount": 0,
      "startTime": 1,
      "endTime": 2,
      "destination": {
        "deviceId": "SIM-1",
        "deviceName": "iPhone 16",
        "architecture": "arm64",
        "modelName": "iPhone 16",
        "osVersion": "18.4"
      },
      "errors": [],
      "warnings": [],
      "analyzerWarnings": []
    }
    """

    private static let compileFailureJSON = """
    {
      "actionTitle": "Build App",
      "status": "failed",
      "errorCount": 1,
      "errors": [
        {
          "issueType": "Swift Compiler Error",
          "message": "Cannot find 'Foo' in scope",
          "sourceURL": "file:///tmp/App/ContentView.swift#StartingLineNumber=17&EndingLineNumber=17"
        }
      ],
      "warnings": [],
      "analyzerWarnings": []
    }
    """

    private static let buildJSONWithSucceededMessageAndError = """
    {
      "status": "failed",
      "errorCount": 1,
      "errors": [
        { "issueType": "error", "message": "BUILD SUCCEEDED" }
      ],
      "warnings": [],
      "analyzerWarnings": []
    }
    """

    private static let urlOnlyFailureSummaryJSON = """
    {
      "title": "Test - App",
      "topInsights": [],
      "result": "Failed",
      "totalTestCount": 1,
      "passedTests": 0,
      "failedTests": 1,
      "skippedTests": 0,
      "expectedFailures": 0,
      "testFailures": [
        {
          "testName": "testLogin()",
          "targetName": "AppTests",
          "failureText": "failed",
          "testIdentifierURL": "test://com.apple.xcode/AppTests/LoginTests/testLogin"
        }
      ]
    }
    """

    private static let failingTestSummaryJSON = """
    {
      "title": "Test - App",
      "environmentDescription": "iPhone 16 • iOS 18.4",
      "topInsights": [],
      "result": "Failed",
      "totalTestCount": 1,
      "passedTests": 0,
      "failedTests": 1,
      "skippedTests": 0,
      "expectedFailures": 0,
      "statistics": [],
      "devicesAndConfigurations": {
        "device": {
          "deviceId": "SIM-1",
          "deviceName": "iPhone 16",
          "architecture": "arm64",
          "modelName": "iPhone 16",
          "osVersion": "18.4"
        },
        "testPlanConfiguration": {
          "configurationId": "1",
          "configurationName": "Test Scheme"
        },
        "passedTests": 0,
        "failedTests": 1,
        "skippedTests": 0,
        "expectedFailures": 0
      },
      "testFailures": [
        {
          "testName": "testLogin()",
          "targetName": "AppTests",
          "failureText": "XCTAssertEqual failed: (\\"a\\") is not equal to (\\"b\\")",
          "testIdentifier": 1,
          "testIdentifierString": "AppTests/LoginTests/testLogin",
          "testIdentifierURL": "test://com.apple.xcode/AppTests/LoginTests/testLogin"
        }
      ]
    }
    """

    private static let singleObjectFailureSummaryJSON = """
    {
      "result": "Failed",
      "totalTestCount": 1,
      "passedTests": 0,
      "failedTests": 1,
      "skippedTests": 0,
      "expectedFailures": 0,
      "testFailures": {
        "testName": "testLogin()",
        "targetName": "AppTests",
        "failureText": "failed",
        "testIdentifier": 1,
        "testIdentifierString": "AppTests/LoginTests/testLogin"
      }
    }
    """

    private static let passedSummaryWithFailureWordingJSON = """
    {
      "title": "All tests failed according to this sentence",
      "environmentDescription": "BUILD FAILED",
      "topInsights": [],
      "result": "Passed",
      "totalTestCount": 1,
      "passedTests": 1,
      "failedTests": 0,
      "skippedTests": 0,
      "expectedFailures": 0,
      "statistics": [{ "title": "BUILD FAILED", "subtitle": "ignored" }],
      "devicesAndConfigurations": {
        "device": {
          "deviceId": "SIM-1",
          "deviceName": "iPhone 16",
          "architecture": "arm64",
          "modelName": "iPhone 16",
          "osVersion": "18.4"
        },
        "testPlanConfiguration": {
          "configurationId": "1",
          "configurationName": "Test Scheme"
        },
        "passedTests": 1,
        "failedTests": 0,
        "skippedTests": 0,
        "expectedFailures": 0
      },
      "testFailures": []
    }
    """

    private static let failingTestsTreeJSON = """
    {
      "testPlanConfigurations": [],
      "devices": [],
      "testNodes": [
        {
          "nodeType": "Test Plan",
          "name": "App",
          "children": [
            {
              "nodeType": "Unit test bundle",
              "name": "AppTests",
              "children": [
                {
                  "nodeType": "Test Suite",
                  "name": "LoginTests",
                  "children": [
                    {
                      "nodeType": "Test Case",
                      "name": "testLogin()",
                      "nodeIdentifier": "AppTests/LoginTests/testLogin",
                      "result": "Failed",
                      "children": [
                        {
                          "nodeType": "Failure Message",
                          "name": "XCTAssertEqual failed"
                        },
                        {
                          "nodeType": "Source Code Reference",
                          "name": "LoginTests.swift:42:18",
                          "details": "file:///tmp/App/LoginTests.swift#StartingLineNumber=42&EndingLineNumber=42"
                        }
                      ]
                    }
                  ]
                }
              ]
            }
          ]
        }
      ]
    }
    """
}

private final class FakeXcresultProcessRunner: ProcessRunning, @unchecked Sendable {
    struct Invocation: Equatable, Sendable {
        var executablePath: String
        var arguments: [String]
        var workingDirectory: String?
        var deadline: Date?
    }

    var availabilityJSON: String?
    var buildJSON: String?
    var testSummaryJSON: String?
    var testsJSON: String?
    var availabilityResult: ProcessResult?
    var buildResult: ProcessResult?
    var testSummaryResult: ProcessResult?
    var testsResult: ProcessResult?

    private(set) var invocations: [Invocation] = []

    var queryNames: [String] {
        invocations.map { invocation in
            if invocation.arguments.contains("content-availability") { return "content-availability" }
            if invocation.arguments.contains("build-results") { return "build-results" }
            if invocation.arguments.contains("summary") { return "test-results-summary" }
            if invocation.arguments.contains("tests") { return "test-results-tests" }
            return invocation.arguments.joined(separator: " ")
        }
    }

    func run(
        executablePath: String,
        arguments: [String],
        workingDirectory: String?,
        deadline: Date?
    ) async throws -> ProcessResult {
        invocations.append(
            Invocation(
                executablePath: executablePath,
                arguments: arguments,
                workingDirectory: workingDirectory,
                deadline: deadline
            )
        )
        if arguments.contains("content-availability") {
            return availabilityResult ?? jsonResult(availabilityJSON)
        }
        if arguments.contains("build-results") {
            return buildResult ?? jsonResult(buildJSON)
        }
        if arguments.contains("summary") {
            return testSummaryResult ?? jsonResult(testSummaryJSON)
        }
        if arguments.contains("tests") {
            return testsResult ?? jsonResult(testsJSON)
        }
        return ProcessResult(exitCode: 1, standardOutput: "", standardError: "unexpected query")
    }

    private func jsonResult(_ json: String?) -> ProcessResult {
        ProcessResult(exitCode: 0, standardOutput: json ?? "{}", standardError: "")
    }
}
