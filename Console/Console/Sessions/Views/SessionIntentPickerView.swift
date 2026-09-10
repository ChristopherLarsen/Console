import SwiftUI

/// Compact launcher: four intent rows and a collapsed Customize area.
/// Sessions always start in the single Session Folder (Settings → Claude).
struct SessionIntentPickerView: View {
    @Environment(SessionStore.self) private var store
    @Environment(SessionLaunchCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    enum Step {
        case intents
        case awaitingNewTicketNumber
        case awaitingJiraContext
        case awaitingMergeRequestContext
    }

    /// What one inline-context submission resolves to before launch: a
    /// parsed artifact source, or a bare story number that only names the
    /// session.
    enum InlineLaunch {
        case source(SessionLaunchSource)
        case namedStory(number: String)
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
            switch step {
            case .intents:
                intentRows
                if let draft { customizeArea(draft: draft) }
            case .awaitingNewTicketNumber:
                newTicketNumberStep
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

            Text(purpose.displayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

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
        case .newTicket: return true
        case .existingTicket: return retainedJiraSource == nil
        case .review: return retainedMergeRequestSource == nil
        case .general: return false
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
        case .newTicket:
            withAnimation(.easeInOut(duration: 0.15)) {
                step = .awaitingNewTicketNumber
            }

        case .general:
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

    private func launch(
        purpose: SessionPurpose,
        source: SessionLaunchSource?,
        nameOverride: String? = nil
    ) {
        var resolvedDraft = coordinator.draft(purpose: purpose, source: source)
        resolvedDraft.name = nameOverride ?? effectiveName(for: resolvedDraft)
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

    /// New Ticket always expands here: the story number is the only input,
    /// and it names the session (`S-1234`). No ticket source is attached.
    private var newTicketNumberStep: some View {
        inlineContextStep(
            title: "Start New Ticket",
            caption: "Enter the NMA story number — the session is named S-1234. Type the work into Claude yourself.",
            placeholder: "1234",
            purpose: .newTicket,
            identifierPrefix: "Sessions.Launcher.NewTicket"
        ) { raw in
            guard let number = NewTicketSessionNaming.storyNumber(fromRaw: raw) else { return nil }
            return .namedStory(number: number)
        }
    }

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
            return .source(SessionLaunchSource.jira(key: key, title: nil, url: url))
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
            return .source(.mergeRequest(iid: info.iid, title: nil, url: mrURL))
        }
    }

    private func inlineContextStep(
        title: String,
        caption: String,
        placeholder: String,
        purpose: SessionPurpose,
        identifierPrefix: String,
        parse: @escaping (String) -> InlineLaunch?
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
        _ parse: (String) -> InlineLaunch?
    ) {
        guard let resolution = parse(inlineContext) else {
            inlineError = "That does not look like a valid source. Check the format and try again."
            return
        }
        inlineError = nil
        switch resolution {
        case let .source(source):
            launch(purpose: purpose, source: source)
        case let .namedStory(number):
            launch(
                purpose: purpose,
                source: nil,
                nameOverride: NewTicketSessionNaming.displayName(forStoryNumber: number)
            )
        }
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