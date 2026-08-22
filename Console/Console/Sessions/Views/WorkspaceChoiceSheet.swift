import SwiftUI

/// Compact chooser shown once when a contextual Jira/MR launch cannot resolve
/// a workspace. Selecting a workspace saves the association and launches
/// immediately; subsequent launches of the same source are one click.
struct WorkspaceChoiceSheet: View {
    let choice: PendingWorkspaceChoice
    let onConfirm: (UUID) -> Void
    let onCancel: () -> Void

    @Environment(SessionWorkspaceStore.self) private var workspaceStore
    @State private var selectedID: UUID?
    @State private var isAddingFolder = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(choice.purpose.displayName)
                    .font(.headline)
                Text("Choose the workspace folder for this source. Your choice is remembered for next time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if workspaceStore.availableWorkspaces.isEmpty {
                emptyWorkspaces
            } else {
                workspaceList
            }

            if let error = validationError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("Sessions.WorkspaceChoice.Error")
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("Sessions.WorkspaceChoice.Cancel")

                Spacer()

                Button("Add Folder…") { chooseFolder() }
                    .accessibilityIdentifier("Sessions.WorkspaceChoice.AddFolder")

                Button("Start Session") {
                    if let selectedID {
                        onConfirm(selectedID)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedID == nil)
                .accessibilityIdentifier("Sessions.WorkspaceChoice.Start")
            }
        }
        .padding(20)
        .frame(width: 420)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SessionWorkspaceChooser")
    }

    private var emptyWorkspaces: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No workspaces configured yet.")
                .font(.subheadline)
            Text("Pick a local folder to continue.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var workspaceList: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(workspaceStore.availableWorkspaces) { workspace in
                    row(for: workspace)
                }
            }
        }
        .frame(maxHeight: 180)
    }

    private func row(for workspace: SessionWorkspace) -> some View {
        Button {
            selectedID = workspace.id
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selectionIcon(for: workspace))
                    .foregroundStyle(selectedID == workspace.id ? Color.accentColor : .secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(workspace.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(workspace.directoryPath)
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selectedID == workspace.id ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Workspace \(workspace.name)")
        .accessibilityAddTraits(selectedID == workspace.id ? [.isSelected] : [])
        .accessibilityIdentifier("Sessions.WorkspaceChoice.Option")
    }

    private func selectionIcon(for workspace: SessionWorkspace) -> String {
        selectedID == workspace.id ? "largecircle.fill.circle" : "circle"
    }

    private var validationError: String? {
        guard let selectedID,
              let workspace = workspaceStore.workspace(withID: selectedID),
              !workspaceStore.isAvailable(workspace) else {
            return nil
        }
        return "That folder is no longer available. Choose another or add a new one."
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose Folder"

        panel.beginSheetModal(for: NSApp.keyWindow ?? NSApp.mainWindow!) { response in
            guard response == .OK, let url = panel.url else { return }
            let workspace = workspaceStore.add(name: url.lastPathComponent, directoryURL: url.standardizedFileURL)
            selectedID = workspace.id
        }
    }
}
