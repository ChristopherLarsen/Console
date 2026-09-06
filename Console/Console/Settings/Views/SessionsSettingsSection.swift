import SwiftUI

/// Settings → Sessions: workspace management, default workspace, and
/// learned-association clearing. This section persists only folders, IDs,
/// and opaque hashes — never source content.
struct SessionsSettingsSection: View {
    @Environment(SessionWorkspaceStore.self) private var workspaceStore
    @State private var renamingID: UUID?
    @State private var renameText = ""

    var body: some View {
        Section {
            workspacesRows
            addWorkspaceRow
            defaultWorkspacePicker
            clearAssociationsRow
        } header: {
            Text("Sessions")
        } footer: {
            Text("Workspaces are local folders Claude sessions can open in. Console remembers which folder belongs to a Jira project or GitLab repository using an irreversible hash — ticket titles, URLs, and repository names are never stored.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var workspacesRows: some View {
        ForEach(workspaceStore.workspaces) { workspace in
            workspaceRow(workspace)
        }
    }

    @ViewBuilder
    private func workspaceRow(_ workspace: SessionWorkspace) -> some View {
        if renamingID == workspace.id {
            HStack {
                TextField("Name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitRename(workspace) }
                    .accessibilityIdentifier("Settings.Sessions.RenameField")

                Button("Save") { commitRename(workspace) }
                    .accessibilityIdentifier("Settings.Sessions.SaveRename")
                Button("Cancel") { renamingID = nil }
            }
        } else {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(workspace.name)
                            .font(.system(size: 13, weight: .medium))

                        if workspaceStore.defaultWorkspaceID == workspace.id {
                            Text("Default")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                                .foregroundStyle(Color.accentColor)
                        }

                        if !workspaceStore.isAvailable(workspace) {
                            Text("Unavailable")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.orange.opacity(0.18)))
                                .foregroundStyle(.orange)
                        }
                    }

                    Text(workspace.directoryPath)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Menu {
                    Button("Rename…") {
                        renamingID = workspace.id
                        renameText = workspace.name
                    }
                    Button("Set as Default") {
                        workspaceStore.setDefault(id: workspace.id)
                    }
                    Button("Remove", role: .destructive) {
                        workspaceStore.remove(id: workspace.id)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)
                .accessibilityLabel("Workspace options for \(workspace.name)")
                .accessibilityIdentifier("Settings.Sessions.WorkspaceMenu")
            }
        }
    }

    private var addWorkspaceRow: some View {
        Button {
            chooseFolder()
        } label: {
            Label("Add Workspace Folder", systemImage: "plus.folder")
        }
        .accessibilityIdentifier("Settings.Sessions.AddWorkspace")
    }

    private var defaultWorkspacePicker: some View {
        Picker("Default Workspace", selection: defaultSelection) {
            Text("None").tag(UUID?.none)
            ForEach(workspaceStore.workspaces) { workspace in
                Text(workspace.name).tag(UUID?.some(workspace.id))
            }
        }
        .accessibilityIdentifier("Settings.Sessions.DefaultPicker")
    }

    private var defaultSelection: Binding<UUID?> {
        Binding(
            get: { workspaceStore.defaultWorkspaceID },
            set: { workspaceStore.setDefault(id: $0) }
        )
    }

    private var clearAssociationsRow: some View {
        Button("Clear Learned Workspace Associations") {
            workspaceStore.clearLearnedAssociations()
        }
        .foregroundStyle(Color.accentColor)
        .accessibilityIdentifier("Settings.Sessions.ClearAssociations")
    }

    private func commitRename(_ workspace: SessionWorkspace) {
        workspaceStore.rename(id: workspace.id, to: renameText)
        renamingID = nil
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
            _ = workspaceStore.add(name: url.lastPathComponent, directoryURL: url.standardizedFileURL)
        }
    }
}
