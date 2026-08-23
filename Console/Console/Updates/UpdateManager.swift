import Foundation
import Observation
import AppKit

/// Drives the source-update flow: check GitHub Releases, qualify one against
/// the running app's version, and prepare a source checkout.
///
/// All state changes happen on the main actor. Concurrent checks or clones are
/// prevented; in-flight work is cancelled on app shutdown. Dependencies are
/// injected so tests never hit the network or run real git.
@MainActor
@Observable
final class UpdateManager {

    enum Phase: Equatable {
        case idle
        case checking
        case current
        case available
        case preparing
        case prepared
        case failed
    }

    private(set) var phase: Phase = .idle
    private(set) var currentVersion: SemanticVersion?
    private(set) var offeredRelease: GitHubRelease?
    private(set) var errorMessage: String?
    private(set) var preparedSource: PreparedSource?

    /// Release suppressed by "Later" for this process only.
    private(set) var dismissedTag: String?

    private let releaseFetcher: any GitHubReleaseFetching
    private let checkout: any SourceCheckouting
    private let projectOpener: any ProjectOpening

    private var checkTask: Task<Void, Never>?
    private var prepareTask: Task<Void, Never>?
    private var didRunAutomaticCheck = false

    init(releaseFetcher: any GitHubReleaseFetching = GitHubReleaseClient(),
         checkout: any SourceCheckouting = SourceCheckoutService(),
         projectOpener: any ProjectOpening = WorkspaceProjectOpener(),
         currentVersion: SemanticVersion? = UpdateManager.runningAppVersion()) {
        self.releaseFetcher = releaseFetcher
        self.checkout = checkout
        self.projectOpener = projectOpener
        self.currentVersion = currentVersion
    }

    // MARK: - Derived state

    var isChecking: Bool { phase == .checking }
    var isPreparing: Bool { phase == .preparing }
    var isBusy: Bool { isChecking || isPreparing }

    /// The app-level prompt appears only while an offer is outstanding and not dismissed.
    var shouldShowPrompt: Bool {
        phase == .available && offeredRelease != nil && offeredRelease?.tagName != dismissedTag
    }

    nonisolated static func runningAppVersion() -> SemanticVersion? {
        guard let raw = BuildConfiguration.appVersion else { return nil }
        return SemanticVersion.parse(raw)
    }

    // MARK: - Checking

    /// The single automatic check per process (non-test Release builds only).
    func performAutomaticCheckIfNeeded() async {
        guard !didRunAutomaticCheck else { return }
        didRunAutomaticCheck = true
        await runCheck(isAutomatic: true)
    }

    /// Manual "Check for Updates" from Settings.
    func checkForUpdates() {
        startCheck(isAutomatic: false)
    }

    private func startCheck(isAutomatic: Bool) {
        guard !isBusy else { return }
        // Reserve the busy phase synchronously so back-to-back calls cannot
        // slip past the guard before the task body starts running.
        phase = .checking
        errorMessage = nil
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            await self?.runCheck(isAutomatic: isAutomatic)
        }
    }

    private func runCheck(isAutomatic: Bool) async {
        phase = .checking
        errorMessage = nil

        do {
            let releases = try await releaseFetcher.fetchReleases()
            try Task.checkCancellation()

            guard let current = currentVersion else {
                phase = .failed
                errorMessage = "Console could not determine its own version, so updates cannot be compared. Try rebuilding the app."
                return
            }

            if let release = GitHubRelease.qualifyingUpdate(from: current, in: releases) {
                offeredRelease = release
                // A manual check re-surfaces an offer the user previously put off with "Later".
                if !isAutomatic { dismissedTag = nil }
                phase = .available
                printDebug("[Updates] Qualifying release available: \(release.tagName)")
            } else {
                offeredRelease = nil
                phase = .current
                printDebug("[Updates] Console is up to date.")
            }
        } catch is CancellationError {
            phase = .idle
        } catch {
            if isAutomatic {
                // Automatic failures are non-blocking and must stay silent.
                printDebug("[Updates] Automatic update check failed quietly: \(error.localizedDescription)")
                offeredRelease = nil
                phase = .idle
            } else {
                printDebug("[Updates] Manual update check failed: \(error.localizedDescription)")
                phase = .failed
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Offer handling

    func dismissOffer() {
        dismissedTag = offeredRelease?.tagName
    }

    func prepareOfferedUpdate() {
        guard let tag = offeredRelease?.tagName, !isBusy else { return }
        phase = .preparing
        errorMessage = nil
        printDebug("[Updates] Preparing source checkout for \(tag)")
        prepareTask?.cancel()
        prepareTask = Task { [weak self] in
            await self?.prepare(tag: tag)
        }
    }

    private func prepare(tag: String) async {
        phase = .preparing
        errorMessage = nil
        printDebug("[Updates] Preparing source checkout for \(tag)")

        do {
            let prepared = try await checkout.prepare(tag: tag)
            preparedSource = prepared
            phase = .prepared
            printDebug("[Updates] Source ready at \(prepared.directoryPath)")
            if let projectPath = prepared.xcodeProjectPath {
                projectOpener.open(path: projectPath)
            }
        } catch is CancellationError {
            phase = .idle
        } catch {
            printDebug("[Updates] Checkout failed: \(error.localizedDescription)")
            phase = .failed
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Shutdown

    /// Cancels any in-flight check or clone. Called when the app terminates.
    func cancelAll() {
        checkTask?.cancel()
        prepareTask?.cancel()
        checkTask = nil
        prepareTask = nil
        if isBusy { phase = .idle }
    }
}

/// Opens a checked-out Xcode project. Injected so tests never launch Xcode.
protocol ProjectOpening: Sendable {
    func open(path: String)
}

struct WorkspaceProjectOpener: ProjectOpening {
    nonisolated init() {}

    func open(path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}
