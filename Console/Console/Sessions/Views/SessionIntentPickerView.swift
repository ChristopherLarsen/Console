import SwiftUI

/// Compact launcher replacing the old Name/Directory sheet: a resolved
/// workspace header, four intent rows, and a collapsed Customize area.
/// New Ticket and General launch with one click once workspaces exist.
struct SessionIntentPickerView: View {
    @Environment(SessionStore.self) private var store
    @Environment(SessionWorkspaceStore.self) private var workspaceStore
    @Environment(SessionLaunchCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    enum Step {
        case intents
        case awaitingJiraContext
        case awaitingMergeRequestContext
    }

    @State private var step: Step = .intents
    @State private var draft: SessionDraft?
    @State private var isCustomizing = false
    @State private var customName = ""
    @State private var overrideWorkspaceID: UUID?
    @State private var inlineContext = ""
    @State private var inlineError: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            workspaceHeader
            Divider()

            switch step {
            case .intents:
                intentRows
                if let draft { customizeArea(draft: draft) }
            case .awaitingJiraContext:
                jiraContextStep
            case .awaitingMergeRequestContext:
                mergeRequestContextStep
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("Sessions.Launcher.Error")
            }
        }
        .padding(16)
        .frame(width: 380)
        // Contain rather than replace: without this the root identifier
        // leaks onto every child and hides the per-row identifiers.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SessionIntentPicker")
    }

    // MARK: - Workspace header

    private var workspaceHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Picker("Workspace", selection: workspaceSelection) {
                if workspaceStore.availableWorkspaces.isEmpty {
                    Text("No Workspaces").tag(UUID?.none)
                } else {
                    Text("Auto").tag(UUID?.none)
                    ForEach(workspaceStore.availableWorkspaces) { workspace in
                        Text("\(workspace.name) — \(activeCount(for: workspace)) active")
                            .tag(UUID?.some(workspace.id))
                    }
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .accessibilityIdentifier("Sessions.Launcher.WorkspacePicker")

            Spacer()

            Button {
                chooseNewWorkspaceFolder()
            } label: {
                Image(systemName: "plus.folder")
            }
            .buttonStyle(.plain)
            .help("Add Workspace Folder")
            .accessibilityIdentifier("Sessions.Launcher.AddWorkspaceButton")
        }
    }

    /// nil selection means "auto" (let resolution decide).
    private var workspaceSelection: Binding<UUID?> {
        Binding(
            get: { overrideWorkspaceID ?? draft?.workspaceID },
            set: { newValue in
                overrideWorkspaceID = newValue
                if var updated = draft {
                    updated.workspaceID = newValue
                    draft = updated
                }
            }
        )
    }

    // MARK: - Intent rows

    private var intentRows: some View {
        VStack(spacing: 6) {
            ForEach(SessionPurpose.allCases, id: \.self) { purpose in
                Button {
                    handleIntentTap(purpose)
                } label: {
                    intentRowLabel(purpose)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(purpose.keyboardCharacter)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(purpose.displayName). \(purpose.intentDescription)")
                .accessibilityIdentifier("Sessions.Intent.\(purpose.rawValue)")
            }
        }
    }

    private func intentRowLabel(_ purpose: SessionPurpose) -> some View {
        HStack(spacing: 10) {
            Image(systemName: purpose.symbolName)
                .font(.system(size: 18))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(purpose.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(purpose.intentDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 0)

            if showsInlineBadge(purpose) {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
    }

    private func showsInlineBadge(_ purpose: SessionPurpose) -> Bool {
        switch purpose {
        case .existingTicket: return retainedJiraSource == nil
        case .review: return retainedMergeRequestSource == nil
        case .newTicket, .general: return false
        }
    }

    private var retainedJiraSource: SessionLaunchSource? { coordinator.retainedJiraSource() }
    private var retainedMergeRequestSource: SessionLaunchSource? { coordinator.retainedMergeRequestSource() }

    // MARK: - Intent handling

    private func handleIntentTap(_ purpose: SessionPurpose) {
        errorMessage = nil
        inlineError = nil

        switch purpose {
        case .newTicket, .general:
            startCleanLaunch(purpose)

        case .existingTicket:
            if let source = retainedJiraSource {
                launch(purpose: .existingTicket, source: source)
            } else {
                withAnimation(.easeInOut(duration: 0.15)) {
                    step = .awaitingJiraContext
                }
            }

        case .review:
            if let source = retainedMergeRequestSource {
                launch(purpose: .review, source: source)
            } else {
                withAnimation(.easeInOut(duration: 0.15)) {
                    step = .awaitingMergeRequestContext
                }
            }
        }
    }

    /// One-click path: resolve (or ask for the first folder), then launch.
    private func startCleanLaunch(_ purpose: SessionPurpose) {
        if workspaceStore.availableWorkspaces.isEmpty && overrideWorkspaceID == nil {
            chooseFirstWorkspaceAndLaunch(purpose: purpose, source: nil)
            return
        }
        launch(purpose: purpose, source: nil)
    }

    private func launch(purpose: SessionPurpose, source: SessionLaunchSource?) {
        var resolvedDraft = coordinator.draft(purpose: purpose, source: source)
        resolvedDraft.name = effectiveName(for: resolvedDraft)
        if let override = overrideWorkspaceID {
            resolvedDraft.workspaceID = override
        }

        if workspaceStore.workspace(withID: resolvedDraft.workspaceID ?? UUID()) == nil,
           workspaceStore.availableWorkspaces.isEmpty {
            chooseFirstWorkspaceAndLaunch(purpose: purpose, source: source)
            return
        }

        do {
            guard try coordinator.launch(draft: resolvedDraft) != nil else {
                errorMessage = "Choose a workspace folder to continue."
                return
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func effectiveName(for resolvedDraft: SessionDraft) -> String {
        let trimmedCustom = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCustom.isEmpty, isCustomizing || customName != coordinator.refreshedName(for: resolvedDraft) {
            return trimmedCustom
        }
        return coordinator.refreshedName(for: resolvedDraft)
    }

    // MARK: - Inline context steps

    private var jiraContextStep: some View {
        inlineContextStep(
            title: "Start Existing Ticket",
            caption: "Enter a Jira issue key or URL.",
            placeholder: "ENG-123",
            purpose: .existingTicket,
            identifierPrefix: "Sessions.Launcher.Jira"
        ) { raw in
            guard let key = JiraSourceContext.parseKey(from: raw) else { return nil }
            let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                $0.host != nil ? $0 : nil
            }
            return SessionLaunchSource.jira(key: key, title: nil, url: url)
        }
    }

    private var mergeRequestContextStep: some View {
        inlineContextStep(
            title: "Start Review",
            caption: "Paste the GitLab merge-request URL.",
            placeholder: "https://gitlab.example.com/group/project/-/merge_requests/42",
            purpose: .review,
            identifierPrefix: "Sessions.Launcher.MergeRequest"
        ) { raw in
            guard let info = MergeRequestSourceContext.parse(from: raw) else { return nil }
            return .mergeRequest(iid: info.iid, title: nil, url: info.projectURL)
        }
    }

    private func inlineContextStep(
        title: String,
        caption: String,
        placeholder: String,
        purpose: SessionPurpose,
        identifierPrefix: String,
        parse: @escaping (String) -> SessionLaunchSource?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    step = .intents
                    inlineContext = ""
                    inlineError = nil
                }
            } label: {
                Label("Back", systemImage: "chevron.left")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .accessibilityIdentifier("\(identifierPrefix).Back")

            Text(title)
                .font(.headline)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $inlineContext)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submitInlineContext(purpose, parse) }
                .accessibilityIdentifier("\(identifierPrefix).Field")

            if let inlineError {
                Text(inlineError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("\(identifierPrefix).Error")
            }

            HStack {
                Spacer()
                Button("Start Session") {
                    submitInlineContext(purpose, parse)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(inlineContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("\(identifierPrefix).StartButton")
            }
        }
    }

    private func submitInlineContext(
        _ purpose: SessionPurpose,
        _ parse: (String) -> SessionLaunchSource?
    ) {
        guard let source = parse(inlineContext) else {
            inlineError = "That does not look like a valid source. Check the format and try again."
            return
        }
        inlineError = nil
        launch(purpose: purpose, source: source)
    }

    // MARK: - Customize area

    private func customizeArea(draft currentDraft: SessionDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isCustomizing.toggle()
                    if isCustomizing {
                        customName = coordinator.refreshedName(for: currentDraft)
                    }
                }
            } label: {
                Label("Customize", systemImage: isCustomizing ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("Sessions.Launcher.CustomizeToggle")

            if isCustomizing {
                HStack(spacing: 8) {
                    Text("Name")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Automatic", text: $customName)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .accessibilityIdentifier("Sessions.Launcher.NameField")

                    Picker("", selection: $overrideWorkspaceID) {
                        Text("Auto").tag(UUID?.none)
                        ForEach(workspaceStore.availableWorkspaces) { workspace in
                            Text(workspace.name).tag(UUID?.some(workspace.id))
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(maxWidth: 140)
                    .accessibilityIdentifier("Sessions.Launcher.CustomWorkspacePicker")
                }

                Text("Leave the name empty to use “\(coordinator.refreshedName(for: currentDraft))”.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Folder choosing

    /// Fresh-install flow: pick one folder; it becomes the default workspace
    /// and the session launches immediately.
    private func chooseFirstWorkspaceAndLaunch(purpose: SessionPurpose, source: SessionLaunchSource?) {
        chooseFolder { url in
            let workspace = workspaceStore.add(name: url.lastPathComponent, directoryURL: url)
            workspaceStore.setDefault(id: workspace.id)
            var resolvedDraft = coordinator.draft(purpose: purpose, source: source)
            resolvedDraft.workspaceID = workspace.id
            resolvedDraft.name = effectiveName(for: resolvedDraft)
            do {
                guard try coordinator.launch(draft: resolvedDraft) != nil else {
                    errorMessage = "The chosen folder could not be used."
                    return
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func chooseNewWorkspaceFolder() {
        chooseFolder { url in
            _ = workspaceStore.add(name: url.lastPathComponent, directoryURL: url)
        }
    }

    private func chooseFolder(_ completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose Folder"
        panel.beginSheetModal(for: NSApp.keyWindow ?? NSApp.mainWindow!) { response in
            guard response == .OK, let url = panel.url else { return }
            completion(url.standardizedFileURL)
        }
    }

    // MARK: - Helpers

    private func activeCount(for workspace: SessionWorkspace) -> Int {
        let rootPath = workspace.directoryPath
        return store.sessions.filter { session in
            guard session.activity != .exited else { return false }
            let sessionPath = session.workingDirectory.standardizedFileURL.path
            return sessionPath == rootPath || sessionPath.hasPrefix(rootPath + "/")
        }.count
    }
}

extension SessionPurpose {
    /// Keyboard shortcuts for the launcher rows.
    var keyboardCharacter: KeyEquivalent {
        switch self {
        case .newTicket: return "1"
        case .existingTicket: return "2"
        case .review: return "3"
        case .general: return "4"
        }
    }
}
