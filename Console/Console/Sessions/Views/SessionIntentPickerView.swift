import SwiftUI

/// Compact launcher: a session-folder header, four intent rows, and a
/// collapsed Customize area. Sessions always start in the single Session
/// Folder (Settings → Claude); a fresh install can pick it inline here.
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
    @State private var inlineContext = ""
    @State private var inlineError: String?
    @State private var errorMessage: String?
    @State private var showsSettingsRoute = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            folderHeader
            Divider()

            switch step {
            case .intents:
                intentRows
                Text(StarterPromptBuilder.developerContextNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("Sessions.Launcher.ContextNotice")
                if let draft { customizeArea(draft: draft) }
            case .awaitingJiraContext:
                jiraContextStep
            case .awaitingMergeRequestContext:
                mergeRequestContextStep
            }

            if let errorMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    if showsSettingsRoute {
                        Button("Open Settings") {
                            ConsoleNavigation.showSettings()
                        }
                        .buttonStyle(.plain)
                        .font(.footnote)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityIdentifier("Sessions.Launcher.OpenSettings")
                    }
                }
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

    // MARK: - Folder header

    private var folderHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)

            if let folder = workspaceStore.defaultFolder {
                VStack(alignment: .leading, spacing: 0) {
                    Text(folder.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(folder.directoryPath)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Text("No Session Folder")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                chooseSessionFolder()
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.plain)
            .help("Choose Session Folder")
            .accessibilityLabel("Choose Session Folder")
            .accessibilityIdentifier("Sessions.Launcher.ChooseFolderButton")
        }
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
        showsSettingsRoute = false
        inlineError = nil
        // Opening Customize snapshots the current intent's automatic name.
        // That snapshot is not a user override: drop it so a different intent
        // regenerates its own automatic name.
        if let previous = draft, customName == coordinator.refreshedName(for: previous) {
            customName = ""
        }

        switch purpose {
        case .newTicket, .general:
            launch(purpose: purpose, source: nil)

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

    private func launch(purpose: SessionPurpose, source: SessionLaunchSource?) {
        var resolvedDraft = coordinator.draft(purpose: purpose, source: source)
        resolvedDraft.name = effectiveName(for: resolvedDraft)
        draft = resolvedDraft

        Task { @MainActor in
            do {
                _ = try await coordinator.launch(draft: resolvedDraft)
                dismiss()
            } catch {
                let failure = SessionLaunchFailure(error: error)
                errorMessage = failure.message
                showsSettingsRoute = failure.offersSettingsRoute
            }
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
            caption: "Enter a Jira issue key or URL to name the session. Type the work into Claude yourself.",
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
            caption: "Paste the GitLab merge-request URL to name the session. Type the review into Claude yourself.",
            placeholder: "https://gitlab.example.com/group/project/-/merge_requests/42",
            purpose: .review,
            identifierPrefix: "Sessions.Launcher.MergeRequest"
        ) { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let info = MergeRequestSourceContext.parse(from: trimmed),
                  let mrURL = URL(string: trimmed) else { return nil }
            // Keep the full MR URL (matching retained-page launches) so
            // artifact URLs point at the merge request, not the project root.
            return .mergeRequest(iid: info.iid, title: nil, url: mrURL)
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
                .disabled(
                    inlineContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
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
                }

                Text("Leave the name empty to use “\(coordinator.refreshedName(for: currentDraft))”.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Folder choosing

    /// Picks the single Session Folder; on a fresh install the next launch
    /// uses it immediately.
    private func chooseSessionFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose Folder"
        panel.beginSheetModal(for: NSApp.keyWindow ?? NSApp.mainWindow!) { response in
            guard response == .OK, let url = panel.url else { return }
            workspaceStore.setDefaultFolderPath(url.standardizedFileURL.path)
        }
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