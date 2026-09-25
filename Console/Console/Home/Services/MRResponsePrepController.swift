import Foundation
import Observation

/// Prepares draft responses to unresolved review comments on the user's own
/// merge requests, proactively and without changing anything.
///
/// After each successful authored-MR scan it fetches the MR's unresolved
/// discussions with read-only glab calls and starts a background, read-only
/// Claude session (`SessionToolProfile.readOnlyPrep`) that drafts an answer
/// per thread. Nothing is committed, pushed, posted or edited; the developer
/// reviews the drafts in that session.
///
/// A merge request is prepared again only when its unresolved-discussion
/// count rises above the count last prepared. State survives relaunch; a
/// prep interrupted by quitting stays reviewable through its transcript.
@MainActor
@Observable
final class MRResponsePrepController {
    /// What a Review column card shows for one merge request.
    enum CardState: Equatable {
        /// Not prepared (automatic prep off, or waiting for a free slot).
        case notPrepared
        /// Fetching evidence or Claude is drafting.
        case preparing
        /// Drafts are ready in the prep session.
        case ready
        /// The prep session ended before finishing; its transcript remains.
        case interrupted
        case failed(String)

        var stateLine: String {
            switch self {
            case .notPrepared: return "Unresolved comments"
            case .preparing: return "Reviewing comments"
            case .ready: return "Response ready"
            case .interrupted: return "Prep interrupted"
            case .failed: return "Prep failed"
            }
        }
    }

    /// Durable per-MR record, keyed by MR URL.
    struct Entry: Codable, Equatable {
        var preparedDiscussionCount: Int
        var claudeSessionID: UUID?
        var sessionName: String?
        var workingDirectory: URL?
        var completed = false
        var failure: String?
    }

    /// Runtime view of one session, decoupled from `ConsoleSession` for tests.
    struct SessionStatus: Equatable {
        let id: UUID
        let claudeSessionID: UUID
        let activity: SessionActivity
        /// The user has this session selected; typing into it could erase
        /// their draft, so a refresh waits for the next scan.
        var isSelected = false
    }

    typealias Fetcher = @MainActor (AuthoredMRAttention, URL) async throws -> Int
    typealias Launcher = @MainActor (AuthoredMRAttention, URL, String, @escaping @MainActor () -> Void)
        async throws -> SessionLaunchCoordinator.BackgroundLaunch
    /// Submits a follow-up prompt into an idle, live prep session.
    typealias Submitter = @MainActor (UUID, String) -> Void

    static let entriesKey = "mrResponsePrepEntries"
    static let maxConcurrentPreps = 2

    /// Merge requests with unresolved discussions from the latest successful
    /// authored scan. Unaffected by the toolbar badge consuming its queue.
    private(set) var items: [AuthoredMRAttention] = []
    private(set) var entries: [String: Entry] = [:]
    private(set) var fetching: Set<URL> = []
    /// Console session IDs whose prep prompt was sent and whose turn has not
    /// finished yet.
    private(set) var awaitingTurn: [UUID: URL] = [:]
    /// Sessions launched but whose prompt has not been typed yet.
    private(set) var launched: [UUID: URL] = [:]

    @ObservationIgnored var sessionsProvider: @MainActor () -> [SessionStatus] = { [] }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fetcher: Fetcher
    @ObservationIgnored private let launcher: Launcher
    @ObservationIgnored private let submitter: Submitter
    @ObservationIgnored private let directoryProvider: (AuthoredMRAttention) -> URL
    @ObservationIgnored private let promptProvider: (AuthoredMRAttention, URL) -> String
    /// Removes evidence folders other than the ones given.
    @ObservationIgnored private let evidenceCleaner: (Set<URL>) -> Void

    init(
        defaults: UserDefaults = .standard,
        fetcher: @escaping Fetcher,
        launcher: @escaping Launcher,
        submitter: @escaping Submitter,
        directoryProvider: @escaping (AuthoredMRAttention) -> URL = { MRResponsePrepFetcher.directory(for: $0) },
        promptProvider: @escaping (AuthoredMRAttention, URL) -> String = MRResponsePrepFetcher.prompt(for:directory:),
        evidenceCleaner: @escaping (Set<URL>) -> Void = { MRResponsePrepFetcher.removeEvidence(keeping: $0) }
    ) {
        self.defaults = defaults
        self.fetcher = fetcher
        self.launcher = launcher
        self.submitter = submitter
        self.directoryProvider = directoryProvider
        self.promptProvider = promptProvider
        self.evidenceCleaner = evidenceCleaner
        if let data = defaults.data(forKey: Self.entriesKey),
           let stored = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = stored
        }
    }

    var isAutomaticPrepEnabled: Bool {
        defaults.object(forKey: AppSettings.mrResponsePrepEnabledKey) as? Bool ?? true
    }

    // MARK: - Scan input

    /// Called with every successful authored-MR scan (an empty list when the
    /// scan scope was reset). Prunes merge requests that no longer have
    /// unresolved discussions and prepares new or grown ones.
    func handleAuthoredScan(_ authored: [AuthoredMRAttention]) {
        items = authored.filter(\.hasDiscussions)
        let current = Set(items.map { $0.url.absoluteString })
        let stale = entries.keys.filter { !current.contains($0) }
        if !stale.isEmpty {
            for key in stale { entries.removeValue(forKey: key) }
            persist()
        }
        // Evidence is company GitLab content: keep it only while its MR is open
        // with unresolved comments.
        evidenceCleaner(Set(items.map(directoryProvider)))
        for item in items {
            guard var entry = entries[item.url.absoluteString],
                  item.unresolvedDiscussionCount < entry.preparedDiscussionCount else { continue }
            // Some threads were resolved: remember the lower count so a new
            // comment raises it again and triggers a fresh prep.
            entry.preparedDiscussionCount = item.unresolvedDiscussionCount
            entries[item.url.absoluteString] = entry
            persist()
        }
        guard isAutomaticPrepEnabled else { return }
        startEligiblePreps()
    }

    /// A merge request needs a prep when it has never been prepared or has
    /// more unresolved discussions than when it was last prepared.
    func needsPrep(_ item: AuthoredMRAttention) -> Bool {
        guard item.hasDiscussions else { return false }
        guard let entry = entries[item.url.absoluteString] else { return true }
        return item.unresolvedDiscussionCount > entry.preparedDiscussionCount
    }

    private func startEligiblePreps() {
        for item in items where needsPrep(item) && !isInFlight(item.url) {
            guard inFlightCount < Self.maxConcurrentPreps else { return }
            prepare(item)
        }
    }

    // MARK: - Prep

    /// Starts (or retries) a prep for one merge request. Reuses the MR's live,
    /// idle prep session with a follow-up prompt; otherwise launches a new
    /// background session. Marked in flight synchronously so a scan can never
    /// start more than `maxConcurrentPreps`.
    @discardableResult
    func prepare(_ item: AuthoredMRAttention) -> Task<Void, Never>? {
        guard !isInFlight(item.url) else { return nil }
        fetching.insert(item.url)
        return Task { await runPrep(item) }
    }

    private func runPrep(_ item: AuthoredMRAttention) async {
        let key = item.url.absoluteString
        let directory = directoryProvider(item)
        let count: Int
        do {
            count = try await fetcher(item, directory)
        } catch {
            fetching.remove(item.url)
            record(key, Entry(preparedDiscussionCount: item.unresolvedDiscussionCount,
                              failure: error.localizedDescription))
            return
        }
        guard count > 0 else {
            fetching.remove(item.url)
            record(key, Entry(preparedDiscussionCount: item.unresolvedDiscussionCount,
                              failure: "GitLab reports no unresolved comments right now."))
            return
        }
        let prompt = promptProvider(item, directory)

        if let previous = entries[key], let claudeID = previous.claudeSessionID,
           let live = liveSession(claudeSessionID: claudeID) {
            guard live.activity == .idle, !live.isSelected else {
                // Busy or in the user's hands: retry on the next scan.
                fetching.remove(item.url)
                return
            }
            submitter(live.id, prompt)
            fetching.remove(item.url)
            awaitingTurn[live.id] = item.url
            var entry = previous
            entry.preparedDiscussionCount = item.unresolvedDiscussionCount
            entry.completed = false
            entry.failure = nil
            record(key, entry)
            return
        }

        do {
            let url = item.url
            let launch = try await launcher(item, directory, prompt) { [weak self] in
                guard let self, let id = self.launched.first(where: { $0.value == url })?.key else { return }
                self.launched.removeValue(forKey: id)
                self.awaitingTurn[id] = url
            }
            fetching.remove(item.url)
            launched[launch.sessionID] = item.url
            record(key, Entry(preparedDiscussionCount: item.unresolvedDiscussionCount,
                              claudeSessionID: launch.claudeSessionID, sessionName: launch.name,
                              workingDirectory: launch.workingDirectory))
        } catch {
            fetching.remove(item.url)
            record(key, Entry(preparedDiscussionCount: item.unresolvedDiscussionCount,
                              failure: error.localizedDescription))
        }
    }

    // MARK: - Session lifecycle

    /// Routed from `SessionStore.addLifecycleSubscriber`.
    func handleLifecycle(sessionID: UUID, event: SessionLifecycleEvent) {
        switch event {
        case .turnCompleted, .completionReported:
            guard let url = awaitingTurn.removeValue(forKey: sessionID) else { return }
            update(url) { $0.completed = true; $0.failure = nil }
            startEligibleAfterSlotFrees()
        case .turnFailed:
            guard let url = awaitingTurn.removeValue(forKey: sessionID) else { return }
            update(url) { $0.failure = "Claude stopped before the drafts were finished." }
            startEligibleAfterSlotFrees()
        case .sessionEnded, .processTerminated:
            let url = awaitingTurn.removeValue(forKey: sessionID) ?? launched.removeValue(forKey: sessionID)
            if url != nil { startEligibleAfterSlotFrees() }
        default:
            break
        }
    }

    private func startEligibleAfterSlotFrees() {
        guard isAutomaticPrepEnabled else { return }
        startEligiblePreps()
    }

    // MARK: - Card state

    func state(for item: AuthoredMRAttention) -> CardState {
        if fetching.contains(item.url) { return .preparing }
        guard let entry = entries[item.url.absoluteString] else { return .notPrepared }
        if let failure = entry.failure { return .failed(failure) }
        if let live = entry.claudeSessionID.flatMap({ liveSession(claudeSessionID: $0) }),
           awaitingTurn[live.id] != nil || launched[live.id] != nil {
            return .preparing
        }
        if entry.completed { return .ready }
        return entry.claudeSessionID == nil ? .notPrepared : .interrupted
    }

    /// The live Console session holding this MR's drafts, if any.
    func liveSessionID(for item: AuthoredMRAttention) -> UUID? {
        entries[item.url.absoluteString]?.claudeSessionID.flatMap { liveSession(claudeSessionID: $0)?.id }
    }

    /// The saved conversation to resume when the prep session is no longer
    /// running (for example after a relaunch).
    func resumableRecord(for item: AuthoredMRAttention) -> SessionRestorationRecord? {
        guard let entry = entries[item.url.absoluteString], let id = entry.claudeSessionID,
              let directory = entry.workingDirectory else { return nil }
        return SessionRestorationRecord(claudeSessionID: id, name: entry.sessionName ?? "MR-\(item.iid) Response",
                                        workingDirectory: directory, purpose: .general)
    }

    // MARK: - Helpers

    private var inFlightCount: Int {
        fetching.count + Set(awaitingTurn.values).union(launched.values).count
    }

    private func isInFlight(_ url: URL) -> Bool {
        fetching.contains(url) || awaitingTurn.values.contains(url) || launched.values.contains(url)
    }

    private func liveSession(claudeSessionID: UUID) -> SessionStatus? {
        sessionsProvider().last { $0.claudeSessionID == claudeSessionID && $0.activity != .exited }
    }

    private func update(_ url: URL, _ change: (inout Entry) -> Void) {
        guard var entry = entries[url.absoluteString] else { return }
        change(&entry)
        record(url.absoluteString, entry)
    }

    private func record(_ key: String, _ entry: Entry) {
        entries[key] = entry
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.entriesKey)
        }
    }
}
