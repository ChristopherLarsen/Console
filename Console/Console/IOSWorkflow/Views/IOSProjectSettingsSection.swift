import SwiftUI

/// Settings → iOS Project: per-workspace Xcode project, scheme, configuration,
/// optional test plan, and Simulator. Discovery is asynchronous; a failed
/// refresh never clears a previously saved profile.
struct IOSProjectSettingsSection: View {
    @Environment(SessionWorkspaceStore.self) private var workspaceStore
    @Environment(IOSProjectProfileStore.self) private var profileStore
    @State private var model = IOSProjectSettingsModel()
    @State private var selectedWorkspaceID: UUID?

    var body: some View {
        Section {
            if workspaceStore.workspaces.isEmpty {
                Text("Add a workspace folder under Sessions to save an iOS project profile.")
                    .foregroundStyle(.secondary)
            } else {
                workspacePicker
                if let workspace {
                    projectPicker(for: workspace)
                    schemePicker(for: workspace)
                    configurationPicker(for: workspace)
                    testPlanPicker(for: workspace)
                    simulatorPicker(for: workspace)
                    statusRows
                }
            }
        } header: {
            Text("iOS Project")
        } footer: {
            Text("Saved locally per workspace: Xcode project, scheme, configuration, optional test plan, and Simulator identifier. Signing credentials and source are never stored.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            if selectedWorkspaceID == nil {
                selectedWorkspaceID = workspaceStore.workspaces.first?.id
            }
            refreshSelected()
        }
        .onChange(of: selectedWorkspaceID) { _, _ in
            refreshSelected()
        }
        .onDisappear {
            model.cancel()
        }
    }

    private var workspace: SessionWorkspace? {
        workspaceStore.workspace(withID: selectedWorkspaceID)
    }

    private var workspacePicker: some View {
        Picker("Workspace", selection: $selectedWorkspaceID) {
            ForEach(workspaceStore.workspaces) { item in
                Text(item.name).tag(Optional(item.id))
            }
        }
        .accessibilityIdentifier("Settings.IOS.WorkspacePicker")
    }

    private func projectPicker(for workspace: SessionWorkspace) -> some View {
        let profile = profileStore.profileOrEmpty(for: workspace.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Xcode Project", selection: projectBinding(for: workspace)) {
                    Text("Choose…").tag(String?.none)
                    ForEach(projectPickerPaths(profile: profile), id: \.self) { path in
                        Text(projectLabel(path: path, profile: profile)).tag(Optional(path))
                    }
                }
                .accessibilityIdentifier("Settings.IOS.ProjectPicker")

                Button("Refresh") {
                    model.refresh(workspace: workspace, store: profileStore)
                }
                .disabled(model.isDiscovering)
                .accessibilityIdentifier("Settings.IOS.RefreshButton")
            }
        }
    }

    private func schemePicker(for workspace: SessionWorkspace) -> some View {
        Picker("Scheme", selection: schemeBinding(for: workspace)) {
            Text("Choose…").tag(String?.none)
            ForEach(schemeOptions(for: workspace), id: \.self) { name in
                Text(schemeLabel(name)).tag(Optional(name))
            }
        }
        .accessibilityIdentifier("Settings.IOS.SchemePicker")
    }

    private func configurationPicker(for workspace: SessionWorkspace) -> some View {
        Picker("Configuration", selection: configurationBinding(for: workspace)) {
            Text("Scheme default").tag(String?.none)
            ForEach(configurationOptions(for: workspace), id: \.self) { name in
                Text(configurationLabel(name)).tag(Optional(name))
            }
        }
        .accessibilityIdentifier("Settings.IOS.ConfigurationPicker")
    }

    private func testPlanPicker(for workspace: SessionWorkspace) -> some View {
        Picker("Test Plan", selection: testPlanBinding(for: workspace)) {
            Text("None").tag(String?.none)
            ForEach(testPlanOptions(for: workspace), id: \.self) { name in
                Text(testPlanLabel(name)).tag(Optional(name))
            }
        }
        .accessibilityIdentifier("Settings.IOS.TestPlanPicker")
    }

    private func simulatorPicker(for workspace: SessionWorkspace) -> some View {
        Picker("Simulator", selection: simulatorBinding(for: workspace)) {
            Text("Choose…").tag(String?.none)
            ForEach(simulatorOptions(for: workspace), id: \.id) { destination in
                Text(destination.displayName).tag(Optional(destination.udid))
            }
            if model.destinationsLookupSucceeded,
               let udid = profileStore.profile(for: workspace.id)?.simulatorUDID,
               !model.destinations.contains(where: { $0.udid == udid }) {
                Text("\(udid) (unavailable)").tag(Optional(udid))
            }
        }
        .accessibilityIdentifier("Settings.IOS.SimulatorPicker")
    }

    @ViewBuilder
    private var statusRows: some View {
        if model.isDiscovering, let progressMessage = model.progressMessage {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(progressMessage)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("Settings.IOS.Progress")
        }

        if let errorMessage = model.errorMessage {
            Text(errorMessage)
                .font(.subheadline)
                .foregroundStyle(.red)
                .accessibilityIdentifier("Settings.IOS.ErrorText")
        }

        ForEach(Array(model.issues.enumerated()), id: \.offset) { _, issue in
            Text(issue.message)
                .font(.subheadline)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("Settings.IOS.RepairWarning")
        }
    }

    private func refreshSelected() {
        guard let workspace else { return }
        model.refresh(workspace: workspace, store: profileStore)
    }

    private func projectPickerPaths(profile: IOSProjectProfile) -> [String] {
        var paths = model.candidates.map(\.path)
        if let saved = profile.projectPath, !paths.contains(saved) {
            paths.insert(saved, at: 0)
        }
        return paths
    }

    private func projectLabel(path: String, profile: IOSProjectProfile) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        if let candidate = model.candidates.first(where: { $0.path == path }) {
            return "\(candidate.displayName) (\(candidate.filename))"
        }
        if profile.projectPath == path,
           model.issues.contains(where: { if case .savedProjectMissing = $0 { return true }; return false }) {
            return "\(name) (missing)"
        }
        return name
    }

    private func schemeOptions(for workspace: SessionWorkspace) -> [String] {
        optionList(
            discovered: model.listing?.schemes ?? [],
            saved: profileStore.profile(for: workspace.id)?.scheme
        )
    }

    private func configurationOptions(for workspace: SessionWorkspace) -> [String] {
        optionList(
            discovered: model.listing?.configurations ?? [],
            saved: profileStore.profile(for: workspace.id)?.configuration
        )
    }

    private func testPlanOptions(for workspace: SessionWorkspace) -> [String] {
        optionList(
            discovered: model.listing?.testPlans ?? [],
            saved: profileStore.profile(for: workspace.id)?.testPlan
        )
    }

    private func simulatorOptions(for _: SessionWorkspace) -> [IOSSimulatorDestination] {
        model.destinations
    }

    private func optionList(discovered: [String], saved: String?) -> [String] {
        var options = discovered
        if let saved, !saved.isEmpty, !options.contains(saved) {
            options.insert(saved, at: 0)
        }
        return options
    }

    private func schemeLabel(_ name: String) -> String {
        missingLabel(name, issueMatches: { if case .savedSchemeMissing(let value) = $0 { return value == name }; return false })
    }

    private func configurationLabel(_ name: String) -> String {
        missingLabel(name, issueMatches: { if case .savedConfigurationMissing(let value) = $0 { return value == name }; return false })
    }

    private func testPlanLabel(_ name: String) -> String {
        missingLabel(name, issueMatches: { if case .savedTestPlanMissing(let value) = $0 { return value == name }; return false })
    }

    private func missingLabel(_ name: String, issueMatches: (IOSProfileRepair.Issue) -> Bool) -> String {
        if model.issues.contains(where: issueMatches) {
            return "\(name) (missing)"
        }
        return name
    }

    private func projectBinding(for workspace: SessionWorkspace) -> Binding<String?> {
        Binding(
            get: { profileStore.profile(for: workspace.id)?.projectPath },
            set: { model.selectProject($0, workspace: workspace, store: profileStore) }
        )
    }

    private func schemeBinding(for workspace: SessionWorkspace) -> Binding<String?> {
        Binding(
            get: { profileStore.profile(for: workspace.id)?.scheme },
            set: { model.selectScheme($0, workspace: workspace, store: profileStore) }
        )
    }

    private func configurationBinding(for workspace: SessionWorkspace) -> Binding<String?> {
        Binding(
            get: { profileStore.profile(for: workspace.id)?.configuration },
            set: { model.selectConfiguration($0, workspaceID: workspace.id, store: profileStore) }
        )
    }

    private func testPlanBinding(for workspace: SessionWorkspace) -> Binding<String?> {
        Binding(
            get: { profileStore.profile(for: workspace.id)?.testPlan },
            set: { model.selectTestPlan($0, workspaceID: workspace.id, store: profileStore) }
        )
    }

    private func simulatorBinding(for workspace: SessionWorkspace) -> Binding<String?> {
        Binding(
            get: { profileStore.profile(for: workspace.id)?.simulatorUDID },
            set: { model.selectSimulator($0, workspaceID: workspace.id, store: profileStore) }
        )
    }
}
