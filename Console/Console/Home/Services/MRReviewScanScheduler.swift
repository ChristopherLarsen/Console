import Foundation

/// Cadence owner for the Home Review column's automated GitLab scans.
///
/// Fires the scan action on a user-configured interval (default 15 minutes)
/// when the scans are enabled and the Web View GitLab Reviews URL is set.
/// The scan action itself is a seam: production triggers the shared
/// reviews-requested list extraction (`MergeRequestListSession`); the AI
/// classification pipeline plugs in behind the same closure later.
///
/// Guards: never two scans in flight, never a scan while disabled or
/// unconfigured. A Settings change restarts the loop so a new interval or
/// toggle takes effect immediately (with one immediate eligible scan).
@MainActor
@Observable
final class MRReviewScanScheduler {

    /// The scan action. Production refreshes the shared reviews-requested
    /// list extraction; tests substitute a recorder.
    typealias ScanPerformer = @MainActor () async -> Void

    // MARK: - Observable state

    private(set) var isScanning = false
    private(set) var lastScanStartedAt: Date?
    private(set) var lastScanFinishedAt: Date?

    // MARK: - Configuration seams

    private let defaults: UserDefaults
    private let reviewsURLProvider: () -> String
    private let performer: ScanPerformer
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
        reviewsURLProvider: @escaping () -> String = { GitLabConfiguration.effectiveReviewsURLString() },
        performer: @escaping ScanPerformer,
        now: @escaping () -> Date = { Date() },
        sleep: @escaping (TimeInterval) async -> Void = { interval in
            try? await Task.sleep(nanoseconds: UInt64(max(0, interval) * 1_000_000_000))
        },
        notificationCenter: NotificationCenter = .default
    ) {
        self.defaults = defaults
        self.reviewsURLProvider = reviewsURLProvider
        self.performer = performer
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
        spawnLoop()
    }

    /// Immediate manual scan, subject to the same guards as a scheduled one.
    func scanNow() {
        beginScanIfEligible(manual: true)
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
        isScanEnabled && ListURLNormalization.url(from: reviewsURLProvider()) != nil
    }

    private var settingsSignature: String {
        "\(isScanEnabled)|\(effectiveIntervalMinutes)|\(reviewsURLProvider())|\(defaults.string(forKey: AppSettings.mrScanModelKey) ?? AppSettings.mrScanModelDefault)"
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
    private func beginScanIfEligible(manual: Bool = false) {
        guard (manual || isScanEnabled), ListURLNormalization.url(from: reviewsURLProvider()) != nil,
              !isScanning else { return }
        isScanning = true
        lastScanStartedAt = now()
        let requestedGeneration = generation
        scanTask = Task { [weak self] in
            guard let self else { return }
            if !Task.isCancelled { await self.performer() }
            self.isScanning = false
            self.scanTask = nil
            guard !Task.isCancelled, self.generation == requestedGeneration else { return }
            self.lastScanFinishedAt = self.now()
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
