import XCTest
@testable import Console

/// Cadence and guard behavior of the MR review scan scheduler. All tests
/// drive the deterministic seams (injected now/sleep/performer) instead of
/// waiting on real intervals, and never start the live timer loop.
@MainActor
final class MRReviewScanSchedulerTests: XCTestCase {
    func testLiveLoopWaitsForScanAndStopRejectsOldCompletion() async {
        let defaults = makeDefaults()
        configure(defaults: defaults, enabled: true)
        var release: CheckedContinuation<Void, Never>?
        var sleeps = 0
        let scheduler = MRReviewScanScheduler(
            defaults: defaults,
            reviewsURLProvider: { "https://gitlab.example.com/project/-/merge_requests" },
            performer: { await withCheckedContinuation { release = $0 } },
            sleep: { _ in
                sleeps += 1
                await Task.yield()
            }
        )
        scheduler.start()
        for _ in 0..<100 where release == nil {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertNotNil(release)
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(sleeps, 1, "The timer must suspend while the scan is running")
        scheduler.stop()
        release?.resume()
        await waitUntilIdle(scheduler)
        XCTAssertNil(scheduler.lastScanFinishedAt, "Cancelled work must not publish completion")
    }

    func testDefaultsNotificationEnablesLiveScheduler() async {
        let defaults = makeDefaults()
        configure(defaults: defaults, enabled: false)
        let center = NotificationCenter()
        var scans = 0
        let scheduler = MRReviewScanScheduler(
            defaults: defaults,
            reviewsURLProvider: { "https://gitlab.example.com/project/-/merge_requests" },
            performer: { scans += 1 },
            notificationCenter: center
        )
        scheduler.start()
        defer { scheduler.stop() }
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(scans, 0)
        defaults.set(true, forKey: AppSettings.mrScanEnabledKey)
        center.post(name: UserDefaults.didChangeNotification, object: defaults)
        for _ in 0..<100 where scans == 0 {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(scans, 1)
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "mr-scan-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// Deterministic clock: reads and advances a single date.
    private final class Clock {
        var current = Date(timeIntervalSince1970: 1_000_000)
        func advance(seconds: TimeInterval) { current.addTimeInterval(seconds) }
    }

    private func makeScheduler(
        defaults: UserDefaults,
        clock: Clock,
        reviewsURL: String,
        performer: @escaping MRReviewScanScheduler.ScanPerformer
    ) -> MRReviewScanScheduler {
        MRReviewScanScheduler(
            defaults: defaults,
            reviewsURLProvider: { reviewsURL },
            performer: performer,
            now: { clock.current },
            sleep: { _ in /* no-op: tests never run the live loop */ },
            notificationCenter: NotificationCenter()
        )
    }

    private func configure(defaults: UserDefaults, enabled: Bool, intervalMinutes: Int = 15) {
        defaults.set(enabled, forKey: AppSettings.mrScanEnabledKey)
        defaults.set(intervalMinutes, forKey: AppSettings.mrScanIntervalMinutesKey)
        defaults.set(AppSettings.mrScanModelDefault, forKey: AppSettings.mrScanModelKey)
    }

    /// Lets a spawned scan task run to completion on the main actor.
    private func waitUntilIdle(_ scheduler: MRReviewScanScheduler) async {
        for _ in 0..<200 {
            if !scheduler.isScanning { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Scan never settled")
    }

    // MARK: - Eligibility

    func testManualRefreshBypassesTimerToggleAndReportsDeferredWithoutSuccessTimestamp() async {
        let defaults = makeDefaults()
        configure(defaults: defaults, enabled: false)
        var triggers: [MRReviewScanTrigger] = []
        let scheduler = MRReviewScanScheduler(
            defaults: defaults,
            reviewsURLProvider: { "https://gitlab.example.test/dashboard/merge_requests" },
            scanPerformer: { trigger in triggers.append(trigger); return .deferred }
        )
        scheduler.scanNow()
        await waitUntilIdle(scheduler)
        XCTAssertEqual(triggers, [.manual])
        XCTAssertEqual(scheduler.lastOutcome, .deferred)
        XCTAssertNil(scheduler.lastScanFinishedAt)
        scheduler.scanOnAppearance()
        await waitUntilIdle(scheduler)
        XCTAssertEqual(triggers, [.manual, .background])
    }

    func testManualUnconfiguredRefreshHasVisibleOutcome() {
        let scheduler = MRReviewScanScheduler(defaults: makeDefaults(), reviewsURLProvider: { "" }, performer: {})
        scheduler.scanNow()
        XCTAssertEqual(scheduler.lastOutcome, .unconfigured)
        XCTAssertFalse(scheduler.isScanning)
    }

    func testIneligibleWhenDisabled() {
        let defaults = makeDefaults()
        configure(defaults: defaults, enabled: false)
        let scheduler = makeScheduler(
            defaults: defaults, clock: Clock(), reviewsURL: "https://gitlab.example.com/proj/-/merge_requests",
            performer: {}
        )
        XCTAssertFalse(scheduler.isEligibleToScan)
    }

    func testIneligibleWhenReviewsURLMissing() {
        let defaults = makeDefaults()
        configure(defaults: defaults, enabled: true)
        let scheduler = makeScheduler(
            defaults: defaults, clock: Clock(), reviewsURL: "   ",
            performer: {}
        )
        XCTAssertFalse(scheduler.isEligibleToScan)
    }

    func testEligibleWhenEnabledAndConfigured() {
        let defaults = makeDefaults()
        configure(defaults: defaults, enabled: true)
        let scheduler = makeScheduler(
            defaults: defaults, clock: Clock(), reviewsURL: "https://gitlab.example.com/proj/-/merge_requests",
            performer: {}
        )
        XCTAssertTrue(scheduler.isEligibleToScan)
    }

    func testIntervalFallsBackToDefaultWhenUnset() {
        let defaults = makeDefaults()
        let scheduler = makeScheduler(defaults: defaults, clock: Clock(), reviewsURL: "", performer: {})
        XCTAssertEqual(scheduler.effectiveIntervalMinutes, AppSettings.mrScanIntervalMinutesDefault)
    }

    // MARK: - fireIfDue

    func testFireIfDuePerformsScanWhenEligible() async {
        let defaults = makeDefaults()
        configure(defaults: defaults, enabled: true)
        let clock = Clock()
        var scanCount = 0
        let scheduler = makeScheduler(defaults: defaults, clock: clock, reviewsURL: "https://gitlab.example.com/proj/-/merge_requests") {
            scanCount += 1
        }

        scheduler.fireIfDue()
        XCTAssertTrue(scheduler.isScanning, "The in-flight guard is claimed synchronously")
        XCTAssertNotNil(scheduler.lastScanStartedAt)
        await waitUntilIdle(scheduler)
        XCTAssertEqual(scanCount, 1)
        XCTAssertNotNil(scheduler.lastScanFinishedAt)
    }

    func testFireIfDueSkipsWhenDisabled() async {
        let defaults = makeDefaults()
        configure(defaults: defaults, enabled: false)
        var scanCount = 0
        let scheduler = makeScheduler(defaults: defaults, clock: Clock(), reviewsURL: "https://gitlab.example.com/proj/-/merge_requests") {
            scanCount += 1
        }

        scheduler.fireIfDue()
        XCTAssertEqual(scanCount, 0)
        XCTAssertNil(scheduler.lastScanStartedAt)
    }

    func testFireIfDueSkipsWhenURLUnconfigured() async {
        let defaults = makeDefaults()
        configure(defaults: defaults, enabled: true)
        var scanCount = 0
        let scheduler = makeScheduler(defaults: defaults, clock: Clock(), reviewsURL: "") {
            scanCount += 1
        }

        scheduler.fireIfDue()
        XCTAssertEqual(scanCount, 0)
    }

    func testFireIfDueWaitsForTheInterval() async {
        let defaults = makeDefaults()
        configure(defaults: defaults, enabled: true)
        let clock = Clock()
        var scanCount = 0
        let scheduler = makeScheduler(defaults: defaults, clock: clock, reviewsURL: "https://gitlab.example.com/proj/-/merge_requests") {
            scanCount += 1
        }

        scheduler.fireIfDue()
        await waitUntilIdle(scheduler)
        XCTAssertEqual(scanCount, 1)

        // Just before the interval elapses the tick is refused.
        clock.advance(seconds: TimeInterval(15 * 60 - 1))
        scheduler.fireIfDue()
        await waitUntilIdle(scheduler)
        XCTAssertEqual(scanCount, 1)

        // At the interval boundary the next tick scans again.
        clock.advance(seconds: 1)
        scheduler.fireIfDue()
        await waitUntilIdle(scheduler)
        XCTAssertEqual(scanCount, 2)
    }

    func testFireIfDueAdvancesScheduleEvenWhenIneligible() async {
        let defaults = makeDefaults()
        configure(defaults: defaults, enabled: false)
        let clock = Clock()
        var scanCount = 0
        let scheduler = makeScheduler(defaults: defaults, clock: clock, reviewsURL: "https://gitlab.example.com/proj/-/merge_requests") {
            scanCount += 1
        }

        scheduler.fireIfDue()
        clock.advance(seconds: TimeInterval(15 * 60))
        scheduler.fireIfDue()
        XCTAssertEqual(scanCount, 0, "An ineligible tick must still advance the schedule, not tight-loop")
    }

    // MARK: - In-flight guard

    func testScanNowSkipsWhilePreviousScanInFlight() async {
        let defaults = makeDefaults()
        configure(defaults: defaults, enabled: true)
        let clock = Clock()
        var scanCount = 0
        let releaseScan = expectation(description: "release scan")
        let scheduler = makeScheduler(defaults: defaults, clock: clock, reviewsURL: "https://gitlab.example.com/proj/-/merge_requests") {
            scanCount += 1
            await self.fulfillment(of: [releaseScan], timeout: 5)
        }

        scheduler.scanNow()
        XCTAssertTrue(scheduler.isScanning)

        // While the first scan is in flight, further triggers are skipped.
        scheduler.scanNow()
        scheduler.scanNow()

        releaseScan.fulfill()
        await waitUntilIdle(scheduler)
        XCTAssertEqual(scanCount, 1)
    }

    // MARK: - Settings changes

    func testSettingsChangeGateIgnoresUnrelatedWrites() {
        XCTAssertFalse(
            MRReviewScanScheduler.shouldRestartOnSettingsChange(lastSignature: nil, newSignature: "true|15|url"),
            "Never started: nothing to restart"
        )
        XCTAssertTrue(
            MRReviewScanScheduler.shouldRestartOnSettingsChange(lastSignature: "true|15|url", newSignature: "false|15|url")
        )
        XCTAssertTrue(
            MRReviewScanScheduler.shouldRestartOnSettingsChange(lastSignature: "true|15|url", newSignature: "true|5|url")
        )
        XCTAssertTrue(
            MRReviewScanScheduler.shouldRestartOnSettingsChange(lastSignature: "true|15|url", newSignature: "true|15|new-url")
        )
        XCTAssertFalse(
            MRReviewScanScheduler.shouldRestartOnSettingsChange(lastSignature: "true|15|url", newSignature: "true|15|url"),
            "Identical settings must not reschedule or trigger a scan"
        )
    }

    func testSettingsChangedIsANoOpWhenNeverStarted() async {
        let defaults = makeDefaults()
        configure(defaults: defaults, enabled: true)
        var scanCount = 0
        let scheduler = makeScheduler(defaults: defaults, clock: Clock(), reviewsURL: "https://gitlab.example.com/proj/-/merge_requests") {
            scanCount += 1
        }

        defaults.set(5, forKey: AppSettings.mrScanIntervalMinutesKey)
        scheduler.settingsChanged()
        scheduler.fireIfDue()
        await waitUntilIdle(scheduler)
        XCTAssertEqual(scanCount, 1, "The scan comes from fireIfDue, not from the no-op settings hook")
    }
}
