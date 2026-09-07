import Foundation

/// Fixed keyboard-first developer actions. Titles are stable menu labels.
nonisolated enum DeveloperActionID: String, CaseIterable, Equatable, Sendable, Identifiable {
    case focusCurrentSession
    case newGeneralSession
    case openWorkspaceInXcode
    case buildSelectedProfile
    case runSelectedTests
    case openLatestResult
    case runInSelectedSimulator

    var id: String { rawValue }

    var title: String {
        switch self {
        case .focusCurrentSession: return "Focus Current Session"
        case .newGeneralSession: return "New General Session"
        case .openWorkspaceInXcode: return "Open Workspace in Xcode"
        case .buildSelectedProfile: return "Build Selected Profile"
        case .runSelectedTests: return "Run Selected Tests"
        case .openLatestResult: return "Open Latest Result"
        case .runInSelectedSimulator: return "Run in Selected Simulator"
        }
    }
}

/// Immutable view of session / iOS-profile / job state used for availability,
/// preview, and routing. Execute the snapshot that produced the preview —
/// do not re-read Settings after the user confirms.
nonisolated struct DeveloperActionSnapshot: Equatable, Sendable {
    var selectedSessionName: String?
    var hasSelectedSession: Bool
    var isFocusMode: Bool
    var hasAvailableWorkspace: Bool
    var workspaceID: UUID?
    var workspaceName: String?
    var profile: IOSProjectProfile?
    var simulatorName: String?
    var latestJobID: UUID?
    var latestSucceededJobID: UUID?
    var latestResultURL: URL?
    var isSimulatorInstalling: Bool

    static let empty = DeveloperActionSnapshot(
        selectedSessionName: nil,
        hasSelectedSession: false,
        isFocusMode: false,
        hasAvailableWorkspace: false,
        workspaceID: nil,
        workspaceName: nil,
        profile: nil,
        simulatorName: nil,
        latestJobID: nil,
        latestSucceededJobID: nil,
        latestResultURL: nil,
        isSimulatorInstalling: false
    )
}

/// What a selected action will use. `profile` is the same value routed to
/// Build / Test / Simulator — preview and execute must match.
nonisolated struct DeveloperActionPreview: Equatable, Sendable {
    var workspaceName: String?
    var scheme: String?
    var deviceName: String?
    var projectName: String?
    var sessionName: String?
    var profile: IOSProjectProfile?
    var summary: String
    var lines: [String]
}

nonisolated enum DeveloperActionRoute: Equatable, Sendable {
    case focusCurrentSession
    case newGeneralSession(workspaceID: UUID)
    case openURL(URL)
    case submitBuild(IOSProjectProfile)
    case submitSelectedTests(IOSProjectProfile)
    case installAndLaunch(jobID: UUID, udid: String, profile: IOSProjectProfile)
    case unavailable(reason: String)
}

nonisolated struct DeveloperActionItem: Equatable, Sendable, Identifiable {
    var id: DeveloperActionID
    var title: String { id.title }
    var isEnabled: Bool
    var disabledReason: String?
    var preview: DeveloperActionPreview
    var route: DeveloperActionRoute
}

/// Availability, preview, search, and routing. No shell strings, no LLM,
/// and no persistent search history.
enum DeveloperActionCatalog {
    static func items(in snapshot: DeveloperActionSnapshot) -> [DeveloperActionItem] {
        DeveloperActionID.allCases.map { item(for: $0, in: snapshot) }
    }

    static func item(for id: DeveloperActionID, in snapshot: DeveloperActionSnapshot) -> DeveloperActionItem {
        let disabledReason = Self.disabledReason(for: id, in: snapshot)
        let preview = Self.preview(for: id, in: snapshot, disabledReason: disabledReason)
        let route: DeveloperActionRoute
        if let disabledReason {
            route = .unavailable(reason: disabledReason)
        } else {
            route = Self.route(for: id, in: snapshot)
        }
        return DeveloperActionItem(
            id: id,
            isEnabled: disabledReason == nil,
            disabledReason: disabledReason,
            preview: preview,
            route: route
        )
    }

    /// In-memory filter only. Matches action titles and iOS profile context,
    /// never persisted, never written to UserDefaults.
    static func matching(_ items: [DeveloperActionItem], query: String) -> [DeveloperActionItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        return items.filter { item in
            if item.title.localizedCaseInsensitiveContains(trimmed) { return true }
            let preview = item.preview
            let fields = [
                preview.workspaceName,
                preview.scheme,
                preview.deviceName,
                preview.projectName
            ]
            return fields.contains { $0?.localizedCaseInsensitiveContains(trimmed) == true }
        }
    }

    static func makeSnapshot(
        selectedSessionName: String?,
        hasSelectedSession: Bool,
        selectedSessionDirectory: URL?,
        isFocusMode: Bool,
        workspaces: [SessionWorkspace],
        defaultWorkspaceID: UUID?,
        profiles: [UUID: IOSProjectProfile],
        jobs: [IOSBuildJob],
        devices: [SimulatorDevice],
        isSimulatorInstalling: Bool,
        bundleExists: (URL) -> Bool
    ) -> DeveloperActionSnapshot {
        let workspace = resolvedWorkspace(
            selectedSessionDirectory: selectedSessionDirectory,
            workspaces: workspaces,
            defaultWorkspaceID: defaultWorkspaceID
        )
        let profile = workspace.flatMap { profiles[$0.id]?.normalized() }
        let udid = profile?.simulatorUDID
        let simulatorName: String?
        if let udid {
            simulatorName = devices.first(where: { $0.udid == udid })?.displayName ?? udid
        } else {
            simulatorName = nil
        }
        let latestResultURL = jobs.reversed().first(where: { bundleExists($0.resultBundleURL) })?.resultBundleURL
        return DeveloperActionSnapshot(
            selectedSessionName: selectedSessionName,
            hasSelectedSession: hasSelectedSession,
            isFocusMode: isFocusMode,
            hasAvailableWorkspace: !workspaces.isEmpty,
            workspaceID: workspace?.id,
            workspaceName: workspace?.name,
            profile: profile,
            simulatorName: simulatorName,
            latestJobID: jobs.last?.id,
            latestSucceededJobID: jobs.last(where: { $0.state == .succeeded })?.id,
            latestResultURL: latestResultURL,
            isSimulatorInstalling: isSimulatorInstalling
        )
    }

    static func disabledReason(for id: DeveloperActionID, in snapshot: DeveloperActionSnapshot) -> String? {
        switch id {
        case .focusCurrentSession:
            if snapshot.hasSelectedSession || snapshot.isFocusMode { return nil }
            return "Select a session before focusing."
        case .newGeneralSession:
            if snapshot.hasAvailableWorkspace, snapshot.workspaceID != nil { return nil }
            return "Add a workspace folder in Settings → Sessions."
        case .openWorkspaceInXcode:
            guard let path = snapshot.profile?.projectPath, IOSProjectCandidate(path: path) != nil else {
                return "Choose an Xcode project in the selected workspace's iOS profile."
            }
            return nil
        case .buildSelectedProfile:
            return buildValidationReason(snapshot.profile)
        case .runSelectedTests:
            return testValidationReason(snapshot.profile)
        case .openLatestResult:
            if snapshot.latestResultURL != nil { return nil }
            return "No local result bundle to open yet."
        case .runInSelectedSimulator:
            if snapshot.isSimulatorInstalling {
                return "A Simulator install is already running."
            }
            if snapshot.latestSucceededJobID == nil {
                return "Select a successful build before installing."
            }
            if IOSProjectProfile.nilIfEmpty(snapshot.profile?.simulatorUDID) == nil {
                return SimulatorServiceError.missingSimulator.errorDescription
            }
            return nil
        }
    }

    static func preview(
        for id: DeveloperActionID,
        in snapshot: DeveloperActionSnapshot,
        disabledReason: String?
    ) -> DeveloperActionPreview {
        let projectName = snapshot.profile?.projectPath.map {
            URL(fileURLWithPath: $0).lastPathComponent
        }
        var lines: [String] = []
        if let workspaceName = snapshot.workspaceName {
            lines.append("Workspace: \(workspaceName)")
        }
        if let projectName {
            lines.append("Project: \(projectName)")
        }
        if let scheme = snapshot.profile?.scheme {
            lines.append("Scheme: \(scheme)")
        }
        if let device = snapshot.simulatorName {
            lines.append("Device: \(device)")
        }
        if id == .focusCurrentSession, let session = snapshot.selectedSessionName {
            lines.append("Session: \(session)")
        }
        if let disabledReason {
            lines.append(disabledReason)
        } else {
            lines.append(enabledSummary(for: id, in: snapshot))
        }
        return DeveloperActionPreview(
            workspaceName: snapshot.workspaceName,
            scheme: snapshot.profile?.scheme,
            deviceName: snapshot.simulatorName,
            projectName: projectName,
            sessionName: snapshot.selectedSessionName,
            profile: snapshot.profile,
            summary: disabledReason ?? enabledSummary(for: id, in: snapshot),
            lines: lines
        )
    }

    static func route(for id: DeveloperActionID, in snapshot: DeveloperActionSnapshot) -> DeveloperActionRoute {
        if let reason = disabledReason(for: id, in: snapshot) {
            return .unavailable(reason: reason)
        }
        switch id {
        case .focusCurrentSession:
            return .focusCurrentSession
        case .newGeneralSession:
            return .newGeneralSession(workspaceID: snapshot.workspaceID!)
        case .openWorkspaceInXcode:
            let path = snapshot.profile!.projectPath!
            return .openURL(URL(fileURLWithPath: path))
        case .buildSelectedProfile:
            return .submitBuild(snapshot.profile!)
        case .runSelectedTests:
            return .submitSelectedTests(snapshot.profile!)
        case .openLatestResult:
            return .openURL(snapshot.latestResultURL!)
        case .runInSelectedSimulator:
            return .installAndLaunch(
                jobID: snapshot.latestSucceededJobID!,
                udid: snapshot.profile!.simulatorUDID!,
                profile: snapshot.profile!
            )
        }
    }

    // MARK: - Internals

    static func resolvedWorkspace(
        selectedSessionDirectory: URL?,
        workspaces: [SessionWorkspace],
        defaultWorkspaceID: UUID?
    ) -> SessionWorkspace? {
        if let directory = selectedSessionDirectory,
           let match = workspaces.first(where: { workspaceContains($0, directory: directory) }) {
            return match
        }
        if let defaultWorkspaceID,
           let match = workspaces.first(where: { $0.id == defaultWorkspaceID }) {
            return match
        }
        return workspaces.first
    }

    private static func workspaceContains(_ workspace: SessionWorkspace, directory: URL) -> Bool {
        let candidate = directory.standardizedFileURL.path
        let root = workspace.directoryPath
        return candidate == root || candidate.hasPrefix(root + "/")
    }

    private static func buildValidationReason(_ profile: IOSProjectProfile?) -> String? {
        guard let profile else {
            return IOSBuildRequestError.missingProject.errorDescription
        }
        do {
            try IOSXcodebuildCommand.validateBuild(profile)
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private static func testValidationReason(_ profile: IOSProjectProfile?) -> String? {
        if let buildReason = buildValidationReason(profile) {
            return buildReason
        }
        let selection = IOSTestSelection().resolving(profile: profile!)
        do {
            try IOSXcodebuildCommand.validateTest(profile!, selection: selection)
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private static func enabledSummary(for id: DeveloperActionID, in snapshot: DeveloperActionSnapshot) -> String {
        let scheme = snapshot.profile?.scheme ?? "the selected scheme"
        let device = snapshot.simulatorName ?? "the selected Simulator"
        switch id {
        case .focusCurrentSession:
            if snapshot.isFocusMode {
                return "Exit Focus Session and restore the previous layout."
            }
            return "Focus the selected session terminal."
        case .newGeneralSession:
            let workspace = snapshot.workspaceName ?? "the selected workspace"
            return "Start a General session in \(workspace)."
        case .openWorkspaceInXcode:
            let project = snapshot.profile?.projectPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "the selected project"
            return "Open \(project) in Xcode."
        case .buildSelectedProfile:
            return "Build \(scheme) on \(device)."
        case .runSelectedTests:
            let plan = snapshot.profile?.testPlan ?? "the selected tests"
            return "Run \(plan) for \(scheme) on \(device)."
        case .openLatestResult:
            return "Open the latest local result bundle in Xcode."
        case .runInSelectedSimulator:
            return "Install and launch the latest successful build on \(device)."
        }
    }
}
