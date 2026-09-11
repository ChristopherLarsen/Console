import Foundation

/// Cadence owner for the Home Review column's automated GitLab scans.
///
/// Fires the scan action on a user-configured interval (default 15 minutes)
/// when scans are enabled and the GitLab reviews URL is set.
///
/// Guards: never two scans in flight, never a scan while disabled or
/// unconfigured. A Settings change restarts the loop so a new interval or
/// toggle takes effect immediately (with one immediate eligible scan).
@MainActor
@Observable
final class MRReviewScanScheduler {

    /// Production runs the glab AI source; tests substitute a recorder.
    typealias ScanPerformer = @MainActor () async -> Void
    typealias ScanAction = @MainActor (MRReviewScanTrigger) async -> MRReviewScanOutcome

    // MARK: - Observable state

    private(set) var isScanning = false
    private(set) var lastScanStartedAt: Date?
    private(set) var lastScanFinishedAt: Date?
    private(set) var lastOutcome: MRReviewScanOutcome?
    let source: MRReviewScanController

    // MARK: - Configuration seams

    private let defaults: UserDefaults
    private let reviewsURLProvider: @MainActor () -> String
    private let performer: ScanAction
    private let requiresGLabPreflight: Bool
    private let now: () -> Date
    private let sleep: (TimeInterval) async -> Void
    private let notificationCenter: NotificationCenter

    // MARK: - Scheduling state

    private var loopTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var generation = 0
    private var settingsObserver: NSObjectProtocol?
    /// Signature of the scan-relevant settings, so the loop only restarts
    /// when the toggle, interval, or reviews URL actually changed — any
    /// unrelated UserDefaults write must not trigger a scan.
    private var lastSettingsSignature: String?
    /// When the next scheduled scan may fire. `start` seeds it with the
    /// current time so the first scan is immediate (subject to guards).
    private var nextScanDate: Date?

    init(
        defaults: UserDefaults = .standard,
        reviewsURLProvider: @escaping @MainActor () -> String = { GitLabConfiguration.effectiveReviewsURLString() },
        performer: ScanPerformer? = nil,
        scanPerformer: ScanAction? = nil,
        source: MRReviewScanController? = nil,
        now: @escaping () -> Date = { Date() },
        sleep: @escaping (TimeInterval) async -> Void = { interval in
            try? await Task.sleep(nanoseconds: UInt64(max(0, interval) * 1_000_000_000))
        },
        notificationCenter: NotificationCenter = .default
    ) {
        let source = source ?? MRReviewScanController.shared
        self.defaults = defaults
        self.reviewsURLProvider = reviewsURLProvider
        self.requiresGLabPreflight = performer == nil && scanPerformer == nil
        self.performer = scanPerformer ?? { trigger in
            if let performer {
                await performer()
                return .refreshed(0)
            }
            return await source.scan(trigger: trigger)
        }
        self.source = source
        self.now = now
        self.sleep = sleep
        self.notificationCenter = notificationCenter
    }

    // MARK: - Lifecycle

    /// Idempotent. Starts the interval loop and observes Settings changes.
    func start() {
        guard loopTask == nil else { return }
        lastSettingsSignature = settingsSignature
        nextScanDate = now()
        installSettingsObserver()
        spawnLoop()
    }

    /// Cancels the loop and observation. Safe to call repeatedly; `start`
    /// may begin a fresh lifecycle afterwards.
    func stop() {
        generation += 1
        scanTask?.cancel()
        loopTask?.cancel()
        loopTask = nil
        nextScanDate = nil
        if let observer = settingsObserver {
            notificationCenter.removeObserver(observer)
            settingsObserver = nil
        }
    }

    /// A scan-relevant setting changed. Restarts the loop so the new toggle,
    /// interval, or URL takes effect immediately (one immediate eligible
    /// scan). Unrelated defaults writes are ignored. No-op when the
    /// scheduler was never started.
    func settingsChanged() {
        guard loopTask != nil else { return }
        let signature = settingsSignature
        guard Self.shouldRestartOnSettingsChange(lastSignature: lastSettingsSignature, newSignature: signature) else {
            lastSettingsSignature = signature
            return
        }
        lastSettingsSignature = signature
        source.settingsChanged()
        spawnLoop()
    }

    /// Explicit refresh bypasses the timer toggle and browsing deferral.
    func scanNow() {
        guard !requiresGLabPreflight || source.checkGLabAvailability(manual: true) else {
            lastOutcome = .failed
            return
        }
        beginScanIfEligible(manual: true, trigger: .manual)
    }

    /// Home entry checks run only when stale, independently of the timer toggle.
    func scanOnAppearance() {
        guard HomeSourcesCoordinator.needsAutoRefresh(lastRefreshedAt: source.lastSuccessfulUpdate, now: now())
                || source.status.check == .stale else { return }
        beginScanIfEligible(manual: true, trigger: .background)
    }

    // MARK: - Settings readers

    var isScanEnabled: Bool {
        defaults.bool(forKey: AppSettings.mrScanEnabledKey)
    }

    var effectiveIntervalMinutes: Int {
        let stored = defaults.integer(forKey: AppSettings.mrScanIntervalMinutesKey)
        return stored > 0 ? min(stored, 1440) : AppSettings.mrScanIntervalMinutesDefault
    }

    /// True when scans are enabled and the reviews URL is usable.
    var isEligibleToScan: Bool {
        isScanEnabled && MRReviewTriagePrompt.configuredURL(reviewsURLProvider()) != nil
    }

    private var settingsSignature: String {
        "\(isScanEnabled)|\(effectiveIntervalMinutes)|\(reviewsURLProvider())|\(source.settingsSignature)"
    }

    // MARK: - Loop

    private func spawnLoop() {
        generation += 1
        scanTask?.cancel()
        loopTask?.cancel()
        nextScanDate = now()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runLoop()
        }
        loopTask = task
    }

    private func runLoop() async {
        while !Task.isCancelled {
            if let scanTask {
                await scanTask.value
                guard !Task.isCancelled else { return }
            }
            let interval = TimeInterval(effectiveIntervalMinutes * 60)
            let due = nextScanDate ?? now().addingTimeInterval(interval)
            let delay = max(0, due.timeIntervalSince(now()))
            await sleep(delay)
            guard !Task.isCancelled else { return }
            fireIfDue()
        }
    }

    /// Fires a scan when one is due. Internal so tests drive the decision
    /// deterministically instead of waiting on real intervals. Schedule
    /// bookkeeping happens synchronously on the caller; the scan body runs
    /// in a detached-from-loop task so a slow scan never delays the loop.
    func fireIfDue() {
        let current = now()
        if let nextScanDate, current < nextScanDate { return }
        nextScanDate = current.addingTimeInterval(TimeInterval(effectiveIntervalMinutes * 60))
        guard isEligibleToScan else {
            // Advance the schedule even on an ineligible tick so a disabled
            // scheduler never tight-loops; a Settings change restarts sooner.
            nextScanDate = current.addingTimeInterval(TimeInterval(effectiveIntervalMinutes * 60))
            return
        }
        beginScanIfEligible()
    }

    /// Single entry into a scan. The in-flight guard is claimed
    /// synchronously on the caller so two rapid triggers cannot both pass,
    /// and the second call is observably skipped.
    private func beginScanIfEligible(manual: Bool = false, trigger: MRReviewScanTrigger = .background) {
        guard manual || isScanEnabled else { return }
        guard MRReviewTriagePrompt.configuredURL(reviewsURLProvider()) != nil else {
            lastOutcome = .unconfigured
            return
        }
        guard !isScanning else {
            if manual { lastOutcome = .alreadyRefreshing }
            return
        }
        isScanning = true
        lastOutcome = nil
        lastScanStartedAt = now()
        let requestedGeneration = generation
        scanTask = Task { [weak self] in
            guard let self else { return }
            let outcome = Task.isCancelled ? .cancelled : await self.performer(trigger)
            self.isScanning = false
            self.scanTask = nil
            guard !Task.isCancelled, self.generation == requestedGeneration else { return }
            self.lastOutcome = outcome
            if outcome.succeeded { self.lastScanFinishedAt = self.now() }
            self.nextScanDate = self.now().addingTimeInterval(
                TimeInterval(self.effectiveIntervalMinutes * 60)
            )
        }
    }

    /// True when the loop should respawn because a scan-relevant setting
    /// actually changed. Pure, so tests verify the gate directly.
    nonisolated static func shouldRestartOnSettingsChange(
        lastSignature: String?,
        newSignature: String
    ) -> Bool {
        guard let lastSignature else { return false }
        return lastSignature != newSignature
    }

    // MARK: - Settings observation

    private func installSettingsObserver() {
        guard settingsObserver == nil else { return }
        settingsObserver = notificationCenter.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.settingsChanged()
            }
        }
    }
}
