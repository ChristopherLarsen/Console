import SwiftUI

/// "Previous Sessions" modal opened from the New Session launcher. Lists
/// Claude's local transcript history as resume cards, filtered to the
/// configured Session Folder by default or across All Projects, ordered by
/// most recently active.
struct PreviousSessionsView: View {
    @Environment(SessionStore.self) private var store
    @Environment(SessionLaunchCoordinator.self) private var coordinator
    @Environment(SessionWorkspaceStore.self) private var workspaceStore
    @Environment(\.dismiss) private var dismiss

    @State private var model = PreviousSessionsModel()
    @State private var scope: SessionHistoryScope = .sessionFolder
    @State private var searchText = ""
    @State private var resumingSessionIDs: Set<UUID> = []
    @State private var errorMessage: String?

    /// Called when the modal finishes: successful resume or handed-off
    /// shared-checkout warning. The launcher closes with it.
    let onFinished: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            controls
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand { dismiss() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("PreviousSessions")
        .task { await model.load() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Previous Sessions")
                .font(.headline)
            Spacer(minLength: 8)
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

            Spacer(minLength: 8)

            Toggle("All Projects", isOn: Binding(
                get: { scope == .allProjects },
                set: { scope = $0 ? .allProjects : .sessionFolder }
            ))
            .toggleStyle(.checkbox)
            .font(.callout)
            .accessibilityIdentifier("PreviousSessions.AllProjectsToggle")
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
                messageView("Choose a Session Folder in Settings → Claude, or turn on All Projects.")
            } else if displayedRecords.isEmpty {
                messageView(
                    searchText.isEmpty
                        ? "No previous sessions found."
                        : "No sessions match your search."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(displayedRecords) { record in
                            PreviousSessionCard(
                                record: record,
                                isResuming: resumingSessionIDs.contains(record.id)
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
        scope == .sessionFolder && workspaceStore.defaultFolder == nil
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
        if scope == .sessionFolder, let folder = workspaceStore.defaultFolder {
            let canonical = CheckoutPath.canonical(folder.directoryURL)
            records = records.filter { CheckoutPath.canonical($0.workingDirectory) == canonical }
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
                let sessionID = try await coordinator.launchResume(record: restoration)
                // Success launches the terminal; nil means the shared-checkout
                // warning is pending at MainView and needs this modal gone so
                // its sheet is visible. Either way close modal and launcher.
                if sessionID != nil || coordinator.pendingCollision != nil {
                    onFinished()
                }
                dismiss()
            } catch {
                errorMessage = SessionLaunchFailure(error: error).message
            }
        }
    }
}

/// Data source for the modal: transcript metadata loaded off the main actor
/// through `SessionHistoryReader`.
@MainActor
@Observable
final class PreviousSessionsModel {
    private(set) var records: [SessionHistoryRecord] = []
    private(set) var isLoading = false
    private(set) var loadErrorMessage: String?

    private let reader: SessionHistoryReader

    init(reader: SessionHistoryReader? = nil) {
        self.reader = reader ?? SessionHistoryReader()
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        loadErrorMessage = nil
        defer { isLoading = false }
        records = await reader.loadRecords()
    }
}

// MARK: - Card

/// One previous session. White background marks an identifiable ticket
/// session; other sessions sit on the neutral card background.
struct PreviousSessionCard: View {
    let record: SessionHistoryRecord
    let isResuming: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
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
                    metaSeparator
                    Label(
                        SessionHistoryFormatting.transcriptSize(record.transcriptByteCount),
                        systemImage: "doc.text"
                    )
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Transcript size")
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
        .buttonStyle(.plain)
        .disabled(isResuming || record.isWorkingDirectoryMissing)
        .opacity(isResuming ? 0.6 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cardAccessibilityLabel)
        .accessibilityHint(record.isWorkingDirectoryMissing ? "Folder missing; cannot resume" : "Resumes this session")
        .accessibilityIdentifier("PreviousSessions.Card.\(record.claudeSessionID.uuidString)")
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
