import SwiftUI

/// Previous Claude transcripts as resume cards. The New Session launcher
/// presents this as a modal ("Select a previous session"). The sidebar page
/// uses the same list and adds Trash on hover, which moves that transcript
/// to the Trash. Cards are filtered to the configured Session Folder, ordered
/// by most recently active.
struct PreviousSessionsView: View {
    @Environment(SessionStore.self) private var store
    @Environment(SessionLaunchCoordinator.self) private var coordinator
    @Environment(SessionWorkspaceStore.self) private var workspaceStore
    @Environment(\.dismiss) private var dismiss

    @State private var model = PreviousSessionsModel()
    @State private var searchText = ""
    @State private var onlyNMAOrMR = true
    @State private var resumingSessionIDs: Set<UUID> = []
    @State private var errorMessage: String?

    /// The New Session sheet shows a close button and dismisses after a
    /// successful resume. The sidebar page does not.
    var showsDismissButton: Bool = true
    /// Sidebar page: hover reveals Trash, which moves the transcript file
    /// to the Trash and drops the card.
    var allowsDeletion: Bool = false
    /// Called when the modal finishes a successful resume. The launcher
    /// closes with it.
    var onFinished: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            controls
            content
            if showAllSessionsFooter && !noSessionFolder && model.loadErrorMessage == nil {
                Divider()
                allSessionsFooter
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand { dismiss() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("PreviousSessions")
        .task {
            model.useWorkAssociations(store.associations)
            await model.load()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text(showsDismissButton ? "Select a previous session" : "Previous Sessions")
                .font(.headline)
            Spacer(minLength: 8)
            if showsDismissButton {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close")
                .accessibilityLabel("Close Previous Sessions")
                .accessibilityIdentifier("PreviousSessions.CloseButton")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Search previous sessions", text: $searchText)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("PreviousSessions.SearchField")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )

            Toggle("NMA/MR", isOn: $onlyNMAOrMR)
                .toggleStyle(.checkbox)
                .fixedSize()
                .help("Show only sessions associated with an NMA story or merge request")
                .accessibilityIdentifier("PreviousSessions.NMAOrMRFilter")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let loadError = model.loadErrorMessage {
            messageView(loadError)
        } else if model.isLoading && model.records.isEmpty {
            VStack(spacing: 8) {
                ProgressView()
                Text("Reading previous sessions…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("PreviousSessions.Loading")
        } else {
            cardList
        }
    }

    private var cardList: some View {
        Group {
            if noSessionFolder {
                messageView("Choose a Session Folder in Settings → Claude.")
            } else if displayedRecords.isEmpty {
                messageView(
                    searchText.isEmpty
                        ? (onlyNMAOrMR ? "No NMA/MR sessions found. Uncheck NMA/MR to show other sessions." : "No previous sessions found.")
                        : "No sessions match your search."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(displayedRecords) { record in
                            PreviousSessionCard(
                                record: record,
                                isResuming: resumingSessionIDs.contains(record.id),
                                onDelete: allowsDeletion ? { trash(record) } : nil
                            ) {
                                resume(record)
                            }
                        }

                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottom) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .accessibilityIdentifier("PreviousSessions.Error")
            }
        }
    }

    private var noSessionFolder: Bool {
        workspaceStore.defaultFolder == nil
    }

    /// The expansion footer appears while the default recent-50 list is
    /// shown — including while a full load is in flight, when it renders
    /// progress — and hides once everything is loaded or while searching
    /// (expansion would not change a filtered-out list).
    private var showAllSessionsFooter: Bool {
        !model.isShowingAllSessions
            && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.records.isEmpty
    }

    /// Indexes every available transcript, not just the most recent 50.
    private var allSessionsFooter: some View {
        HStack(spacing: 6) {
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
                Text("Loading all sessions…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    Task { await model.loadAllSessions() }
                } label: {
                    Label("All sessions", systemImage: "clock.arrow.circlepath")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .help("Index every previous session instead of the 50 most recent")
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityIdentifier("PreviousSessions.AllSessionsButton")
    }

    private func messageView(_ text: String) -> some View {
        VStack(spacing: 6) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("PreviousSessions.EmptyState")
    }

    /// Session Folder scope first, then the search query across title,
    /// folder, branch, and ticket key.
    private var displayedRecords: [SessionHistoryRecord] {
        var records = model.records
        if let folder = workspaceStore.defaultFolder {
            let canonical = CheckoutPath.canonical(folder.directoryURL)
            records = records.filter { CheckoutPath.canonical($0.workingDirectory) == canonical }
        }
        if onlyNMAOrMR {
            records = records.filter { $0.isAssociatedWithNMAOrMR(artifacts: store.associations.artifacts(for: $0.id)) }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            records = records.filter { record in
                record.title.localizedCaseInsensitiveContains(query)
                    || record.workingDirectory.path.localizedCaseInsensitiveContains(query)
                    || (record.gitBranch?.localizedCaseInsensitiveContains(query) ?? false)
                    || (record.ticketKey?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }
        return records.sorted { $0.lastActive > $1.lastActive }
    }

    // MARK: - Resume

    private func resume(_ record: SessionHistoryRecord) {
        guard !resumingSessionIDs.contains(record.id) else { return }
        resumingSessionIDs.insert(record.id)
        errorMessage = nil

        let restoration = SessionRestorationRecord(
            claudeSessionID: record.claudeSessionID,
            name: record.title,
            workingDirectory: record.workingDirectory,
            purpose: .general
        )
        Task { @MainActor in
            defer { resumingSessionIDs.remove(record.id) }
            do {
                _ = try await coordinator.launchResume(record: restoration)
                // Success launches the terminal. The modal also closes
                // itself and the New Session launcher; the sidebar page
                // stays until Sessions becomes the selection.
                if showsDismissButton {
                    onFinished()
                    dismiss()
                }
            } catch {
                errorMessage = SessionLaunchFailure(error: error).message
            }
        }
    }

    /// Moves the transcript to the Trash, then drops the card. A failed
    /// move leaves the card in place.
    private func trash(_ record: SessionHistoryRecord) {
        errorMessage = nil
        do {
            try model.moveTranscriptToTrash(record)
        } catch {
            errorMessage = "Couldn't move “\(record.title)” to the Trash."
        }
    }
}

/// Data source for the modal: transcript metadata loaded off the main actor
/// through `SessionHistoryReader`. The first load indexes only the most
/// recent 50 transcripts; "All sessions" re-indexes everything available.
@MainActor
@Observable
final class PreviousSessionsModel {
    private(set) var records: [SessionHistoryRecord] = []
    private(set) var isLoading = false
    private(set) var loadErrorMessage: String?
    private(set) var isShowingAllSessions = false

    private let reader: SessionHistoryReader
    private let trashTranscript: (URL) throws -> Void

    init(
        reader: SessionHistoryReader? = nil,
        trashTranscript: @escaping (URL) throws -> Void = { _ = try ClaudeSessionTranscriptTrash.moveToTrash($0) }
    ) {
        self.reader = reader ?? SessionHistoryReader()
        self.trashTranscript = trashTranscript
    }

    /// Moves the transcript file to the Trash and drops it from the list.
    /// A missing file still drops the card. A failed move throws and leaves
    /// the card in place.
    func moveTranscriptToTrash(_ record: SessionHistoryRecord) throws {
        if FileManager.default.fileExists(atPath: record.transcriptURL.path) {
            try trashTranscript(record.transcriptURL)
        }
        reader.forgetTranscript(at: record.transcriptURL)
        records.removeAll { $0.claudeSessionID == record.claudeSessionID }
    }

    func useWorkAssociations(_ store: SessionAssociationStore) {
        reader.useWorkAssociations(store)
    }

    func load() async {
        await load(limit: SessionHistoryReader.defaultScanLimit, showingAll: false)
    }

    func loadAllSessions() async {
        await load(limit: nil, showingAll: true)
    }

    private func load(limit: Int?, showingAll: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        loadErrorMessage = nil
        defer { isLoading = false }
        records = await reader.loadRecords(limit: limit)
        isShowingAllSessions = showingAll
    }
}

// MARK: - Card

/// One previous session. White background marks an identifiable ticket
/// session; other sessions sit on the neutral card background.
struct PreviousSessionCard: View {
    let record: SessionHistoryRecord
    let isResuming: Bool
    var onDelete: (() -> Void)? = nil
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: action) {
                cardContents
            }
            .buttonStyle(.plain)
            .disabled(isResuming || record.isWorkingDirectoryMissing)
            .opacity(isResuming ? 0.6 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(cardAccessibilityLabel)
            .accessibilityHint(record.isWorkingDirectoryMissing ? "Folder missing; cannot resume" : "Resumes this session")
            .accessibilityIdentifier("PreviousSessions.Card.\(record.claudeSessionID.uuidString)")

            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(10)
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
                .accessibilityHidden(!isHovered)
                .accessibilityLabel("Move \(record.title) to the Trash")
                .accessibilityIdentifier("PreviousSessions.Trash.\(record.claudeSessionID.uuidString)")
                .help("Move to the Trash")
                .zIndex(1)
            }
        }
        .onHover { isHovered = $0 }
    }

    private var cardContents: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(record.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if record.isWorkingDirectoryMissing {
                    Text("Folder missing")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.red)
                }
                if let key = record.ticketKey {
                    Text(key)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                        .help("Ticket session")
                }
                if onDelete != nil {
                    Color.clear
                        .frame(width: 22, height: 22)
                        .accessibilityHidden(true)
                }
            }

            HStack(spacing: 5) {
                Text(SessionHistoryFormatting.relativeLastActive(record.lastActive))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(SessionHistoryFormatting.exactLastActive(record.lastActive))
                if let branch = record.gitBranch {
                    metaSeparator
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(record.workingDirectory.path)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
                .help(record.workingDirectory.path)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
    }

    /// Ticket sessions are white; other sessions sit on light gray.
    private var cardBackground: Color {
        record.isTicketSession
            ? Color(nsColor: .controlBackgroundColor)
            : Color(nsColor: .windowBackgroundColor)
    }

    private var cardAccessibilityLabel: String {
        var parts = [record.title]
        if let key = record.ticketKey { parts.append("Ticket \(key)") }
        if record.isWorkingDirectoryMissing { parts.append("Folder missing") }
        return parts.joined(separator: ". ")
    }

    private var metaSeparator: some View {
        Text("·")
            .font(.caption)
            .foregroundStyle(.tertiary)
    }
}
