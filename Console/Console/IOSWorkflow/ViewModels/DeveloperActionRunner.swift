import Foundation

/// Live objects the keyboard actions share with the corresponding buttons.
@MainActor
struct DeveloperActionHosts {
    var sessionStore: SessionStore
    var layout: SessionWorkspaceLayoutController
    var workspaceStore: SessionWorkspaceStore
    var profileStore: IOSProjectProfileStore
    var buildCoordinator: IOSBuildCoordinator
    var launchCoordinator: SessionLaunchCoordinator
}

/// Presents the action picker and routes confirmed actions through the same
/// coordinators as Settings / Sessions buttons. Search text is not stored here.
@MainActor
@Observable
final class DeveloperActionRunner {
    var isPickerPresented = false
    var lastActionMessage: String?
    private(set) var lastExecutedProfile: IOSProjectProfile?
    private(set) var lastRoute: DeveloperActionRoute?

    @ObservationIgnored let opener: any IOSWorkspaceOpening
    @ObservationIgnored let bundleExists: (URL) -> Bool
    let simulatorModel: IOSSimulatorLaunchModel

    init(
        opener: (any IOSWorkspaceOpening)? = nil,
        simulatorModel: IOSSimulatorLaunchModel? = nil,
        bundleExists: ((URL) -> Bool)? = nil
    ) {
        self.opener = opener ?? SystemIOSWorkspaceOpener()
        self.simulatorModel = simulatorModel ?? IOSSimulatorLaunchModel()
        self.bundleExists = bundleExists ?? { url in
            FileManager.default.fileExists(atPath: url.path)
        }
    }

    func presentPicker() {
        // A fresh presentation must not show the previous session's failure.
        lastActionMessage = nil
        isPickerPresented = true
    }

    func dismissPicker() {
        isPickerPresented = false
    }

    func snapshot(hosts: DeveloperActionHosts) -> DeveloperActionSnapshot {
        DeveloperActionCatalog.makeSnapshot(
            selectedSessionName: hosts.sessionStore.selectedSession?.name,
            hasSelectedSession: hosts.sessionStore.selectedSession != nil,
            selectedSessionDirectory: hosts.sessionStore.selectedSession?.workingDirectory,
            isFocusMode: hosts.layout.isFocusMode,
            workspaces: hosts.workspaceStore.availableWorkspaces,
            defaultWorkspaceID: hosts.workspaceStore.defaultWorkspaceID,
            profiles: hosts.profileStore.profilesByWorkspaceID,
            jobs: hosts.buildCoordinator.jobs,
            devices: simulatorModel.devices,
            isSimulatorInstalling: simulatorModel.isInstalling,
            bundleExists: bundleExists
        )
    }

    /// Executes `snapshot`'s route, not a later re-read of Settings. Build and
    /// test go through `IOSBuildCoordinator` so a second invoke stays queued.
    func perform(
        _ id: DeveloperActionID,
        snapshot: DeveloperActionSnapshot,
        hosts: DeveloperActionHosts
    ) async {
        let item = DeveloperActionCatalog.item(for: id, in: snapshot)
        lastRoute = item.route
        lastExecutedProfile = item.preview.profile
        switch item.route {
        case .focusCurrentSession:
            hosts.layout.toggleFocusSession()
            hosts.sessionStore.focusSelectedTerminal()
            lastActionMessage = nil
        case .newGeneralSession(let workspaceID):
            var draft = hosts.launchCoordinator.draft(purpose: .general, source: nil)
            draft.workspaceID = workspaceID
            do {
                _ = try await hosts.launchCoordinator.launch(draft: draft)
                lastActionMessage = nil
            } catch {
                lastActionMessage = error.localizedDescription
            }
        case .openURL(let url):
            opener.open(url)
            lastActionMessage = nil
        case .submitBuild(let profile):
            do {
                _ = try hosts.buildCoordinator.submitBuild(profile: profile)
                lastActionMessage = nil
            } catch {
                lastActionMessage = error.localizedDescription
            }
        case .submitSelectedTests(let profile):
            do {
                _ = try hosts.buildCoordinator.submitSelectedTests(profile: profile)
                lastActionMessage = nil
            } catch {
                lastActionMessage = error.localizedDescription
            }
        case .installAndLaunch(let jobID, let udid, _):
            let job = hosts.buildCoordinator.job(id: jobID)
            simulatorModel.installAndLaunch(job: job, udid: udid)
            lastActionMessage = nil
        case .unavailable(let reason):
            lastActionMessage = reason
        }
    }
}
