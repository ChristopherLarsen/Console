import XCTest
@testable import Console

@MainActor
final class UpdateManagerTests: XCTestCase {

    // MARK: - Stubs

    private final class StubReleaseFetcher: GitHubReleaseFetching, @unchecked Sendable {
        var releases: [GitHubRelease] = []
        var error: Error?
        var delay: Duration?
        private(set) var callCount = 0

        func fetchReleases() async throws -> [GitHubRelease] {
            callCount += 1
            if let delay { try await Task.sleep(for: delay) }
            if let error { throw error }
            return releases
        }
    }

    private final class StubCheckout: SourceCheckouting, @unchecked Sendable {
        var result: Result<PreparedSource, Error> = .success(
            PreparedSource(directoryPath: "/tmp/Console-v2.0.0", xcodeProjectPath: nil)
        )
        var hangsUntilCancelled = false
        /// Simulates a clone whose closure ignores task cancellation and
        /// returns success anyway — the manager must still discard it.
        var completesDespiteCancellation = false
        private(set) var preparedTags: [String] = []

        func prepare(tag: String) async throws -> PreparedSource {
            preparedTags.append(tag)
            if hangsUntilCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    if !completesDespiteCancellation { throw CancellationError() }
                }
            }
            return try result.get()
        }
    }

    private final class RecordingOpener: ProjectOpening, @unchecked Sendable {
        private(set) var openedPaths: [String] = []
        func open(path: String) { openedPaths.append(path) }
    }

    private let current = SemanticVersion(major: 1, minor: 2, patch: 3)

    private func release(tag: String, draft: Bool = false, prerelease: Bool = false) -> GitHubRelease {
        GitHubRelease(tagName: tag, name: nil, draft: draft, prerelease: prerelease, htmlURL: nil)
    }

    private func makeManager(
        fetcher: StubReleaseFetcher,
        checkout: StubCheckout,
        opener: RecordingOpener = RecordingOpener()
    ) -> UpdateManager {
        UpdateManager(
            releaseFetcher: fetcher,
            checkout: checkout,
            projectOpener: opener,
            currentVersion: current
        )
    }

    /// Polls until the condition holds; all work runs on the main actor so this
    /// stays deterministic for stub-backed flows.
    private func waitUntil(
        _ condition: @autoclosure () -> Bool,
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "Condition not met within \(timeout)s", file: file, line: line)
    }

    // MARK: - Qualification & phases

    func testQualifyingReleaseIsOfferedWithHighestVersion() async {
        let fetcher = StubReleaseFetcher()
        fetcher.releases = [release(tag: "v1.2.4"), release(tag: "v2.0.0"), release(tag: "v1.3.0")]
        let manager = makeManager(fetcher: fetcher, checkout: StubCheckout())

        manager.checkForUpdates()
        await waitUntil(manager.phase == .available)

        XCTAssertEqual(manager.offeredRelease?.tagName, "v2.0.0")
        XCTAssertTrue(manager.shouldShowPrompt)
        XCTAssertNil(manager.errorMessage)
    }

    func testPatchOnlyChangeNeverQualifies() async {
        let fetcher = StubReleaseFetcher()
        fetcher.releases = [release(tag: "v1.2.4"), release(tag: "v1.2.10")]
        let manager = makeManager(fetcher: fetcher, checkout: StubCheckout())

        manager.checkForUpdates()
        await waitUntil(manager.phase == .current)

        XCTAssertNil(manager.offeredRelease)
        XCTAssertFalse(manager.shouldShowPrompt)
    }

    func testDraftsPrereleasesAndMalformedTagsAreIgnored() async {
        let fetcher = StubReleaseFetcher()
        fetcher.releases = [
            release(tag: "v2.0.0", draft: true),
            release(tag: "v1.9.0-rc1", prerelease: true),
            release(tag: "banana"),
        ]
        let manager = makeManager(fetcher: fetcher, checkout: StubCheckout())

        manager.checkForUpdates()
        await waitUntil(manager.phase == .current)

        XCTAssertNil(manager.offeredRelease)
    }

    // MARK: - Failure handling

    func testManualFailureSurfacesActionableErrorText() async {
        let fetcher = StubReleaseFetcher()
        fetcher.error = UpdateError.httpStatus(503)
        let manager = makeManager(fetcher: fetcher, checkout: StubCheckout())

        manager.checkForUpdates()
        await waitUntil(manager.phase == .failed)

        XCTAssertEqual(manager.errorMessage, "The update server returned HTTP 503.")
        XCTAssertFalse(manager.shouldShowPrompt)
    }

    func testAutomaticFailureIsNonBlockingAndSilent() async {
        let fetcher = StubReleaseFetcher()
        fetcher.error = URLError(.notConnectedToInternet)
        let manager = makeManager(fetcher: fetcher, checkout: StubCheckout())

        await manager.performAutomaticCheckIfNeeded()

        XCTAssertEqual(manager.phase, .idle)
        XCTAssertNil(manager.errorMessage)
        XCTAssertFalse(manager.shouldShowPrompt)
    }

    func testAutomaticCheckRunsOncePerProcess() async {
        let fetcher = StubReleaseFetcher()
        fetcher.error = URLError(.timedOut)
        let manager = makeManager(fetcher: fetcher, checkout: StubCheckout())

        await manager.performAutomaticCheckIfNeeded()
        await manager.performAutomaticCheckIfNeeded()
        await manager.performAutomaticCheckIfNeeded()

        XCTAssertEqual(fetcher.callCount, 1)
    }

    // MARK: - Later / re-surface

    func testLaterSuppressesPromptUntilNextManualCheck() async {
        let fetcher = StubReleaseFetcher()
        fetcher.releases = [release(tag: "v1.3.0")]
        let manager = makeManager(fetcher: fetcher, checkout: StubCheckout())

        manager.checkForUpdates()
        await waitUntil(manager.shouldShowPrompt)

        manager.dismissOffer()
        XCTAssertFalse(manager.shouldShowPrompt)
        XCTAssertEqual(manager.phase, .available, "Settings still shows the offer")

        manager.checkForUpdates()
        await waitUntil(manager.shouldShowPrompt, timeout: 2)
    }

    // MARK: - Concurrency guards

    func testConcurrentChecksArePrevented() async {
        let fetcher = StubReleaseFetcher()
        fetcher.delay = .milliseconds(80)
        fetcher.releases = [release(tag: "v1.3.0")]
        let manager = makeManager(fetcher: fetcher, checkout: StubCheckout())

        manager.checkForUpdates()
        manager.checkForUpdates()
        manager.checkForUpdates()
        await waitUntil(!manager.isBusy)

        XCTAssertEqual(fetcher.callCount, 1, "checks issued while busy must be ignored")
        XCTAssertEqual(manager.phase, .available)
        XCTAssertEqual(manager.offeredRelease?.tagName, "v1.3.0")
    }

    func testCheckIsBlockedWhilePreparing() async {
        let fetcher = StubReleaseFetcher()
        fetcher.releases = [release(tag: "v2.0.0")]
        let checkout = StubCheckout()
        checkout.hangsUntilCancelled = true
        let manager = makeManager(fetcher: fetcher, checkout: checkout)

        manager.checkForUpdates()
        await waitUntil(manager.phase == .available)

        manager.prepareOfferedUpdate()
        await waitUntil(!checkout.preparedTags.isEmpty)
        XCTAssertEqual(checkout.preparedTags, ["v2.0.0"])
        XCTAssertTrue(manager.isPreparing)

        manager.checkForUpdates()
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(manager.isChecking, "a manual check must not run while a clone is in flight")

        manager.cancelAll()
        await waitUntil(!manager.isBusy)
        XCTAssertEqual(manager.phase, .idle)
    }

    // MARK: - Preparing

    func testSuccessfulPreparationReportsSourcePath() async {
        let fetcher = StubReleaseFetcher()
        fetcher.releases = [release(tag: "v2.0.0")]
        let checkout = StubCheckout()
        checkout.result = .success(PreparedSource(
            directoryPath: "~/Developer/ConsoleUpdates/Console-v2.0.0",
            xcodeProjectPath: "~/Developer/ConsoleUpdates/Console-v2.0.0/Console/Console.xcodeproj"
        ))
        let opener = RecordingOpener()
        let manager = makeManager(fetcher: fetcher, checkout: checkout, opener: opener)

        manager.checkForUpdates()
        await waitUntil(manager.phase == .available)

        manager.prepareOfferedUpdate()
        await waitUntil(manager.phase == .prepared)

        XCTAssertEqual(manager.preparedSource?.directoryPath, "~/Developer/ConsoleUpdates/Console-v2.0.0")
        XCTAssertEqual(
            opener.openedPaths,
            ["~/Developer/ConsoleUpdates/Console-v2.0.0/Console/Console.xcodeproj"]
        )
        XCTAssertNil(manager.errorMessage)
        XCTAssertFalse(manager.shouldShowPrompt, "prompt disappears once preparation completes")
    }

    func testFailedPreparationShowsActionableError() async {
        let fetcher = StubReleaseFetcher()
        fetcher.releases = [release(tag: "v2.0.0")]
        let checkout = StubCheckout()
        checkout.result = .failure(SourceCheckoutError.commandFailed(description: "Downloading source", exitCode: 128, stderr: "fatal: tag not found"))
        let opener = RecordingOpener()
        let manager = makeManager(fetcher: fetcher, checkout: checkout, opener: opener)

        manager.checkForUpdates()
        await waitUntil(manager.phase == .available)

        manager.prepareOfferedUpdate()
        await waitUntil(manager.phase == .failed)

        XCTAssertTrue(manager.errorMessage?.contains("tag not found") ?? false)
        XCTAssertTrue(opener.openedPaths.isEmpty, "Xcode must not open after a failed checkout")
    }

    // MARK: - Shutdown cancellation

    func testCancelAllAbortsInFlightWork() async {
        let fetcher = StubReleaseFetcher()
        fetcher.releases = [release(tag: "v2.0.0")]
        let checkout = StubCheckout()
        checkout.hangsUntilCancelled = true
        let manager = makeManager(fetcher: fetcher, checkout: checkout)

        manager.checkForUpdates()
        await waitUntil(manager.phase == .available)

        manager.prepareOfferedUpdate()
        await waitUntil(manager.isPreparing)

        manager.cancelAll()
        await waitUntil(!manager.isBusy)

        XCTAssertEqual(manager.phase, .idle)
    }

    func testCancelAllDuringCheckReturnsToIdleQuietly() async {
        let fetcher = StubReleaseFetcher()
        fetcher.delay = .seconds(30)
        let manager = makeManager(fetcher: fetcher, checkout: StubCheckout())

        manager.checkForUpdates()
        await waitUntil(manager.isChecking)

        manager.cancelAll()
        await waitUntil(!manager.isBusy)

        XCTAssertEqual(manager.phase, .idle)
        XCTAssertNil(manager.errorMessage)
    }

    // MARK: - H46-F02: quit-time cancellation must suppress success side effects

    func testCancelledPrepareDoesNotReportSuccessOrOpenXcode() async {
        let fetcher = StubReleaseFetcher()
        fetcher.releases = [release(tag: "v2.0.0")]
        let checkout = StubCheckout()
        checkout.hangsUntilCancelled = true
        checkout.completesDespiteCancellation = true
        checkout.result = .success(PreparedSource(
            directoryPath: "/tmp/Console-v2.0.0",
            xcodeProjectPath: "/tmp/Console-v2.0.0/Console/Console.xcodeproj"
        ))
        let opener = RecordingOpener()
        let manager = makeManager(fetcher: fetcher, checkout: checkout, opener: opener)

        manager.checkForUpdates()
        await waitUntil(manager.phase == .available)

        manager.prepareOfferedUpdate()
        await waitUntil(!checkout.preparedTags.isEmpty)

        manager.cancelAll()
        await waitUntil(!manager.isBusy)

        XCTAssertEqual(manager.phase, .idle, "a cancelled prepare must not report success")
        XCTAssertNil(manager.preparedSource)
        XCTAssertTrue(opener.openedPaths.isEmpty, "Xcode must not open after quit-time cancellation")
    }

    // MARK: - H46-F03: failed prepare keeps the offer retryable

    func testFailedPreparationKeepsOfferRetryableWithoutRecheck() async {
        let fetcher = StubReleaseFetcher()
        fetcher.releases = [release(tag: "v2.0.0")]
        let checkout = StubCheckout()
        checkout.result = .failure(SourceCheckoutError.commandFailed(
            description: "Downloading source", exitCode: 128, stderr: "fatal: tag not found"
        ))
        let opener = RecordingOpener()
        let manager = makeManager(fetcher: fetcher, checkout: checkout, opener: opener)

        manager.checkForUpdates()
        await waitUntil(manager.phase == .available)

        manager.prepareOfferedUpdate()
        await waitUntil(manager.phase == .failed)

        XCTAssertTrue(manager.canRetryPreparation, "the same offer must stay retryable")
        XCTAssertFalse(manager.shouldShowPrompt, "the modal prompt stays down after failure")

        // Retry the same offer without any network re-check.
        checkout.result = .success(PreparedSource(
            directoryPath: "/tmp/Console-v2.0.0",
            xcodeProjectPath: "/tmp/Console-v2.0.0/Console/Console.xcodeproj"
        ))
        manager.prepareOfferedUpdate()
        await waitUntil(manager.phase == .prepared)

        XCTAssertEqual(checkout.preparedTags, ["v2.0.0", "v2.0.0"])
        XCTAssertEqual(opener.openedPaths, ["/tmp/Console-v2.0.0/Console/Console.xcodeproj"])
    }

    // MARK: - H46-F04: automatic check shares the tracked check path

    func testCancelAllAbortsInFlightAutomaticCheck() async {
        let fetcher = StubReleaseFetcher()
        fetcher.releases = [release(tag: "v2.0.0")]
        fetcher.delay = .seconds(30)
        let manager = makeManager(fetcher: fetcher, checkout: StubCheckout())

        let autoTask = Task { await manager.performAutomaticCheckIfNeeded() }
        await waitUntil(manager.isChecking)

        manager.cancelAll()
        await waitUntil(!manager.isBusy)

        XCTAssertEqual(manager.phase, .idle, "shutdown must cancel the automatic check")
        XCTAssertEqual(fetcher.callCount, 1)
        _ = await autoTask.value
    }

    func testManualCheckDuringAutomaticCheckDoesNotDoubleFetch() async {
        let fetcher = StubReleaseFetcher()
        fetcher.releases = [release(tag: "v1.3.0")]
        fetcher.delay = .milliseconds(80)
        let manager = makeManager(fetcher: fetcher, checkout: StubCheckout())

        let autoTask = Task { await manager.performAutomaticCheckIfNeeded() }
        await waitUntil(manager.isChecking)

        manager.checkForUpdates()
        await autoTask.value

        XCTAssertEqual(fetcher.callCount, 1, "a manual check must not race the automatic check")
        XCTAssertEqual(manager.phase, .available)
    }

    func testAutomaticCheckIsSkippedWhenManualCheckIsInFlight() async {
        let fetcher = StubReleaseFetcher()
        fetcher.releases = [release(tag: "v1.3.0")]
        fetcher.delay = .milliseconds(80)
        let manager = makeManager(fetcher: fetcher, checkout: StubCheckout())

        manager.checkForUpdates()
        await waitUntil(manager.isChecking)

        await manager.performAutomaticCheckIfNeeded()
        await waitUntil(manager.phase == .available)

        XCTAssertEqual(fetcher.callCount, 1, "the pending bootstrap check must not run a second fetch")
        XCTAssertEqual(manager.offeredRelease?.tagName, "v1.3.0")
    }
}
