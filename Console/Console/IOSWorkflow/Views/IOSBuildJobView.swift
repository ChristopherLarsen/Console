import SwiftUI

/// Settings → iOS Jobs: compact progress, Stop, elapsed time, result state,
/// first actionable issue, expandable local output, and result actions.
/// Errors stay on-device — they are not sent to an LLM.
struct IOSBuildJobView: View {
    @Environment(IOSBuildCoordinator.self) private var coordinator
    @Environment(IOSProjectProfileStore.self) private var profileStore
    @Environment(SessionWorkspaceStore.self) private var workspaceStore
    @State private var model = IOSBuildJobPanelModel()
    @State private var simulatorModel = IOSSimulatorLaunchModel()

    var body: some View {
        @Bindable var model = model
        @Bindable var simulatorModel = simulatorModel
        Section {
            if workspaceStore.workspaces.isEmpty && coordinator.jobs.isEmpty {
                Text("Add a workspace and iOS project profile to run Build or Selected Tests.")
                    .foregroundStyle(.secondary)
            } else {
                if !workspaceStore.workspaces.isEmpty {
                    workspacePicker
                    actionRow
                    IOSSimulatorLaunchView(
                        model: simulatorModel,
                        workspaceID: model.resolveWorkspaceID(from: workspaceStore),
                        selectedJob: model.selectedJob(from: coordinator.jobs),
                        profileStore: profileStore
                    )
                }
                if let message = model.actionMessage {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("Settings.IOS.Jobs.ActionMessage")
                }
                jobList
                if let job = model.selectedJob(from: coordinator.jobs) {
                    jobDetail(job)
                } else if coordinator.jobs.isEmpty {
                    Text("No iOS jobs yet.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("Settings.IOS.Jobs.Empty")
                }
            }
        } header: {
            Text("iOS Jobs")
        } footer: {
            Text("Result bundles and job output stay on this Mac. Console does not upload them or send errors to an AI provider.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("Settings.IOS.Jobs")
        .onAppear {
            if model.selectedWorkspaceID == nil {
                model.selectedWorkspaceID = model.resolveWorkspaceID(from: workspaceStore)
            }
            model.selectLatestIfNeeded(from: coordinator.jobs)
        }
        .onChange(of: coordinator.jobs.count) { _, _ in
            model.selectLatestIfNeeded(from: coordinator.jobs)
        }
    }

    private var workspacePicker: some View {
        Picker("Workspace", selection: workspaceBinding) {
            ForEach(workspaceStore.workspaces) { item in
                Text(item.name).tag(Optional(item.id))
            }
        }
        .accessibilityIdentifier("Settings.IOS.Jobs.WorkspacePicker")
    }

    private var workspaceBinding: Binding<UUID?> {
        Binding(
            get: { model.resolveWorkspaceID(from: workspaceStore) },
            set: { model.selectedWorkspaceID = $0 }
        )
    }

    private var activeProfile: IOSProjectProfile? {
        guard let workspaceID = model.resolveWorkspaceID(from: workspaceStore) else { return nil }
        return profileStore.profile(for: workspaceID)
    }

    private var actionRow: some View {
        HStack {
            Button("Build") {
                guard let profile = activeProfile else {
                    model.actionMessage = IOSBuildRequestError.missingProject.errorDescription
                    return
                }
                model.submitBuild(coordinator: coordinator, profile: profile)
            }
            .disabled(activeProfile == nil)
            .accessibilityIdentifier("Settings.IOS.Jobs.Build")

            Button("Run Selected Tests") {
                guard let profile = activeProfile else {
                    model.actionMessage = IOSBuildRequestError.missingProject.errorDescription
                    return
                }
                model.submitSelectedTests(coordinator: coordinator, profile: profile)
            }
            .disabled(activeProfile == nil)
            .accessibilityIdentifier("Settings.IOS.Jobs.RunSelectedTests")

            Spacer()
        }
    }

    @ViewBuilder
    private var jobList: some View {
        if !coordinator.jobs.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(coordinator.jobs.reversed()) { job in
                    jobRow(job)
                }
            }
        }
    }

    private func jobRow(_ job: IOSBuildJob) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let presentation = model.presentation(for: job, at: timeline.date)
            let selected = model.selectedJob(from: coordinator.jobs)?.id == job.id
            Button {
                model.selectedJobID = job.id
            } label: {
                HStack(spacing: 8) {
                    if presentation.isInProgress {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text(presentation.title)
                        .lineLimit(1)
                    Spacer()
                    Text(presentation.stateTitle)
                        .foregroundStyle(stateColor(presentation.state))
                    Text(presentation.elapsedText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("Settings.IOS.Jobs.Elapsed")
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? Color.accentColor.opacity(0.12) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("Settings.IOS.Jobs.Row.\(job.id.uuidString)")
        }
    }

    private func jobDetail(_ job: IOSBuildJob) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let presentation = model.presentation(for: job, at: timeline.date)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if presentation.isInProgress {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(presentation.stateTitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(stateColor(presentation.state))
                        .accessibilityIdentifier("Settings.IOS.Jobs.State")
                    Text(presentation.elapsedText)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop") {
                        model.stop(coordinator: coordinator, jobs: coordinator.jobs)
                    }
                    .disabled(!presentation.canStop)
                    .accessibilityIdentifier("Settings.IOS.Jobs.Stop")
                }

                if let firstIssue = presentation.firstIssueText {
                    Text(firstIssue)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("Settings.IOS.Jobs.FirstIssue")
                }

                if let diagnostic = presentation.diagnosticText {
                    Text(diagnostic)
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("Settings.IOS.Jobs.Diagnostic")
                }

                HStack {
                    Button("Open Result in Xcode") {
                        model.openResult(job: job)
                    }
                    .disabled(!presentation.canOpenResult)
                    .accessibilityIdentifier("Settings.IOS.Jobs.OpenResult")

                    Button("Open Source Location") {
                        model.openSource(job: job)
                    }
                    .disabled(!presentation.canOpenSource && !presentation.canOpenResult)
                    .accessibilityIdentifier("Settings.IOS.Jobs.OpenSource")

                    Button("Copy Error") {
                        model.copyError(job: job)
                    }
                    .disabled(!presentation.canCopyError)
                    .accessibilityIdentifier("Settings.IOS.Jobs.CopyError")

                    Button("Rerun Failed Tests") {
                        model.rerunFailedTests(coordinator: coordinator, job: job)
                    }
                    .disabled(!presentation.canRerunFailedTests)
                    .accessibilityIdentifier("Settings.IOS.Jobs.RerunFailed")
                }

                DisclosureGroup("Output", isExpanded: $model.isOutputExpanded) {
                    ScrollView {
                        Text(presentation.output.isEmpty ? "No output." : presentation.output)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                    .accessibilityIdentifier("Settings.IOS.Jobs.Output")
                }
            }
        }
    }

    private func stateColor(_ state: IOSBuildJobState) -> Color {
        switch state {
        case .queued, .running:
            return .secondary
        case .succeeded:
            return .green
        case .failed, .timedOut:
            return .red
        case .cancelled:
            return .orange
        }
    }
}
