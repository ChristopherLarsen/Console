import AppKit
import SwiftUI

/// Sheet for creating a Claude session: editable name plus a required working
/// directory chosen with NSOpenPanel.
struct NewClaudeSessionSheet: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var workingDirectory: URL?
    @State private var errorMessage: String?
    @State private var isCreating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Claude Session")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Name")
                    .font(.subheadline)
                TextField("Session Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("SessionNameField")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Working Directory")
                    .font(.subheadline)
                HStack {
                    Button("Choose…") { chooseDirectory() }
                        .accessibilityIdentifier("ChooseFolderButton")

                    if let workingDirectory {
                        Text(workingDirectory.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("ChosenFolderPath")
                    } else {
                        Text("Required")
                            .foregroundStyle(.orange)
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("CreateSessionError")
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("CancelSessionButton")

                Button("Create Session") {
                    create()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate || isCreating)
                .accessibilityIdentifier("CreateSessionButton")
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var canCreate: Bool {
        workingDirectory != nil && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose Folder"

        panel.beginSheetModal(for: NSApp.keyWindow ?? NSApp.mainWindow!) { response in
            guard response == .OK, let url = panel.url else { return }
            workingDirectory = url.standardizedFileURL
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                name = store.suggestedName(for: url.standardizedFileURL)
            }
            errorMessage = nil
        }
    }

    private func create() {
        guard let directory = workingDirectory else { return }
        isCreating = true
        errorMessage = nil
        do {
            _ = try store.createSession(
                name: name,
                workingDirectory: directory
            )
            dismiss()
        } catch {
            // Keep the sheet open with an actionable local error.
            errorMessage = error.localizedDescription
            isCreating = false
        }
    }
}
