import Foundation

/// Settings-side discovery session: progress, candidates, and repair issues
/// for the selected workspace. Persistence stays in `IOSProjectProfileStore`.
@MainActor
@Observable
final class IOSProjectSettingsModel {
    enum Phase: Equatable {
        case idle
        case searchingProjects
        case listingSchemes
        case listingTestPlans
        case listingDestinations
        case failed(String)
        case ready
    }

    private(set) var phase: Phase = .idle
    private(set) var candidates: [IOSProjectCandidate] = []
    private(set) var listing: IOSProjectListing?
    private(set) var destinations: [IOSSimulatorDestination] = []
    /// True only when the last completed destination lookup succeeded, so the
    /// UI never labels a saved Simulator "(unavailable)" because the lookup
    /// itself failed or was skipped.
    private(set) var destinationsLookupSucceeded = false
    private(set) var issues: [IOSProfileRepair.Issue] = []

    private let discovery: IOSProjectDiscovery
    private var generation = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    var isDiscovering: Bool {
        switch phase {
        case .searchingProjects, .listingSchemes, .listingTestPlans, .listingDestinations:
            return true
        case .idle, .failed, .ready:
            return false
        }
    }

    var progressMessage: String? {
        switch phase {
        case .searchingProjects: return "Searching for Xcode projects…"
        case .listingSchemes: return "Reading schemes…"
        case .listingTestPlans: return "Reading test plans…"
        case .listingDestinations: return "Finding Simulators…"
        default: return nil
        }
    }

    var errorMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    init(discovery: IOSProjectDiscovery = IOSProjectDiscovery()) {
        self.discovery = discovery
    }

    func refresh(workspace: SessionWorkspace, store: IOSProjectProfileStore) {
        generation += 1
        let current = generation
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.performRefresh(workspace: workspace, store: store, generation: current)
        }
    }

    func refreshAndWait(workspace: SessionWorkspace, store: IOSProjectProfileStore) async {
        generation += 1
        let current = generation
        refreshTask?.cancel()
        await performRefresh(workspace: workspace, store: store, generation: current)
    }

    func cancel() {
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        if isDiscovering {
            phase = .idle
        }
    }

    func selectProject(
        _ path: String?,
        workspace: SessionWorkspace,
        store: IOSProjectProfileStore
    ) {
        var profile = store.profileOrEmpty(for: workspace.id)
        profile.projectPath = path
        store.save(profile)
        refresh(workspace: workspace, store: store)
    }

    func selectScheme(
        _ scheme: String?,
        workspace: SessionWorkspace,
        store: IOSProjectProfileStore
    ) {
        var profile = store.profileOrEmpty(for: workspace.id)
        profile.scheme = scheme
        store.save(profile)
        refresh(workspace: workspace, store: store)
    }

    func selectConfiguration(_ configuration: String?, workspaceID: UUID, store: IOSProjectProfileStore) {
        var profile = store.profileOrEmpty(for: workspaceID)
        profile.configuration = configuration
        store.save(profile)
    }

    func selectTestPlan(_ testPlan: String?, workspaceID: UUID, store: IOSProjectProfileStore) {
        var profile = store.profileOrEmpty(for: workspaceID)
        profile.testPlan = testPlan
        store.save(profile)
    }

    func selectSimulator(_ udid: String?, workspaceID: UUID, store: IOSProjectProfileStore) {
        var profile = store.profileOrEmpty(for: workspaceID)
        profile.simulatorUDID = udid
        store.save(profile)
    }

    private func performRefresh(
        workspace: SessionWorkspace,
        store: IOSProjectProfileStore,
        generation: Int
    ) async {
        phase = .searchingProjects
        candidates = []
        listing = nil
        destinations = []
        destinationsLookupSucceeded = false
        issues = []
        let saved = store.profileOrEmpty(for: workspace.id)
        let expectedGeneration = generation
        let result = await discovery.refresh(
            saved: saved,
            workspaceFolder: workspace.directoryURL
        ) { [weak self] discoveryPhase in
            Task { @MainActor in
                guard let self, self.generation == expectedGeneration else { return }
                self.phase = Self.phase(from: discoveryPhase)
            }
        }
        guard self.generation == expectedGeneration, !Task.isCancelled else { return }

        candidates = result.candidates
        listing = result.listing
        destinations = result.destinations
        if case .succeeded = result.destinationLookup {
            destinationsLookupSucceeded = true
        }
        // Re-resolve against the profile as it stands now, not the snapshot
        // taken at refresh start, so edits made mid-refresh are not clobbered.
        let current = store.profileOrEmpty(for: workspace.id)
        let repair = IOSProfileRepair.resolve(
            saved: current,
            candidates: result.candidates,
            listing: result.listingLookup,
            destinations: result.destinationLookup
        )
        issues = repair.issues
        if repair.didChangeProfile {
            store.save(repair.profile)
        }
        if let errorMessage = result.errorMessage {
            phase = .failed(errorMessage)
        } else {
            phase = .ready
        }
    }

    private static func phase(from discovery: IOSDiscoveryPhase) -> Phase {
        switch discovery {
        case .searchingProjects: return .searchingProjects
        case .listingSchemes: return .listingSchemes
        case .listingTestPlans: return .listingTestPlans
        case .listingDestinations: return .listingDestinations
        }
    }
}
