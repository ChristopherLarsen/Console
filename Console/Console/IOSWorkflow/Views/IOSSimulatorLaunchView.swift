import SwiftUI

/// Compact Simulator picker and install/launch controls for the iOS jobs panel.
struct IOSSimulatorLaunchView: View {
    @Bindable var model: IOSSimulatorLaunchModel
    var workspaceID: UUID?
    var selectedJob: IOSBuildJob?
    var profileStore: IOSProjectProfileStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            picker
            Text(model.affectedDeviceSummary(udid: selectedUDID))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .accessibilityIdentifier("Settings.IOS.Simulator.AffectedDevice")

            HStack {
                Button("Open Simulator") {
                    model.openSimulator(udid: selectedUDID)
                }
                .disabled(selectedUDID == nil || model.isInstalling)
                .accessibilityIdentifier("Settings.IOS.Simulator.Open")

                Button("Install & Launch") {
                    model.installAndLaunch(job: selectedJob, udid: selectedUDID)
                }
                .disabled(!model.canInstall(job: selectedJob, udid: selectedUDID))
                .accessibilityIdentifier("Settings.IOS.Simulator.InstallLaunch")

                Button("Cancel Wait") {
                    model.cancelWaiting()
                }
                .disabled(!model.canCancelWait)
                .accessibilityIdentifier("Settings.IOS.Simulator.Cancel")

                Spacer()
            }

            if model.isInstalling || model.isListing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    if let statusText = model.statusText {
                        Text(statusText)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("Settings.IOS.Simulator.Status")
            } else if case .succeeded = model.phase, let statusText = model.statusText {
                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("Settings.IOS.Simulator.Status")
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("Settings.IOS.Simulator.Error")
            }
        }
        .accessibilityIdentifier("Settings.IOS.Simulator")
        .onAppear {
            model.refreshDevices()
        }
        .onDisappear {
            model.cancel()
        }
        .onChange(of: workspaceID) { _, _ in
            model.refreshDevices()
        }
    }

    private var selectedUDID: String? {
        if model.isInstalling, let udid = model.activeInstallUDID {
            return udid
        }
        guard let workspaceID else { return nil }
        return profileStore.profile(for: workspaceID)?.simulatorUDID
    }

    private var picker: some View {
        Picker("Simulator", selection: simulatorBinding) {
            Text("Choose…").tag(String?.none)
            ForEach(model.devices) { device in
                Text(device.displayName).tag(Optional(device.udid))
            }
            if let udid = selectedUDID, !model.devices.contains(where: { $0.udid == udid }) {
                Text("\(udid) (unavailable)").tag(Optional(udid))
            }
        }
        .disabled(model.isInstalling)
        .accessibilityIdentifier("Settings.IOS.Simulator.Picker")
    }

    private var simulatorBinding: Binding<String?> {
        Binding(
            get: { selectedUDID },
            set: { newValue in
                guard let workspaceID else { return }
                model.selectSimulator(newValue, workspaceID: workspaceID, store: profileStore)
            }
        )
    }
}
