import SwiftUI

/// Historical links are explicit: similarity never silently selects a conversation.
struct AuthoredMRSessionPicker: View {
    let item: AuthoredMRAttention
    @Environment(SessionLaunchCoordinator.self) private var coordinator
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var model = PreviousSessionsModel()
    @State private var search = ""
    @State private var errorMessage: String?
    @State private var busy = false

    private var records: [SessionRestorationRecord] {
        var result = store.sessions.filter { $0.purpose != .blank && $0.activity != .exited }.map {
            SessionRestorationRecord(claudeSessionID: $0.claudeSessionID, name: $0.name,
                workingDirectory: $0.workingDirectory, purpose: $0.purpose ?? .general)
        }
        let live = Set(result.map(\.id))
        result += model.records.filter { !live.contains($0.claudeSessionID) }.map {
            SessionRestorationRecord(claudeSessionID: $0.claudeSessionID, name: $0.title,
                workingDirectory: $0.workingDirectory,
                purpose: store.associations.conversation($0.claudeSessionID)?.record.purpose ?? .general)
        }
        return result.filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                || $0.workingDirectory.path.localizedCaseInsensitiveContains(search)
                || (store.associations.conversation($0.id)?.artifacts.contains {
                    $0.label.localizedCaseInsensitiveContains(search)
                } ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Link authoring Session").font(.headline)
            Text("\(item.project) !\(item.iid) — \(item.title)").lineLimit(2)
            Text("Choose the conversation for this work, or start a new Session. Console will remember your choice.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Search Sessions or folders", text: $search)
            if model.isLoading { ProgressView("Loading previous Sessions…") }
            List(records) { record in
                Button { open(record) } label: {
                    VStack(alignment: .leading) {
                        Text(record.name).lineLimit(1)
                        Text(record.workingDirectory.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).disabled(busy)
            }
            if let message = errorMessage ?? model.loadErrorMessage ?? coordinator.lastFailureMessage {
                Text(message).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("New Session") { open(nil) }.disabled(busy)
            }
        }
        .padding(20)
        .frame(width: 580, height: 480)
        .interactiveDismissDisabled(busy)
        .task {
            await model.loadAllSessions()
            for record in model.records {
                do {
                    try store.associations.remember(record: .init(claudeSessionID: record.claudeSessionID,
                        name: record.title, workingDirectory: record.workingDirectory,
                        purpose: store.associations.conversation(record.claudeSessionID)?.record.purpose ?? .general),
                        artifacts: record.ticketKey.map { [.init(kind: .jiraIssue, label: $0)] } ?? [])
                } catch {
                    errorMessage = "Previous Session links could not be saved: \(error.localizedDescription)"
                    break
                }
            }
        }
    }

    private func open(_ record: SessionRestorationRecord?) {
        busy = true
        errorMessage = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await coordinator.linkAuthoredMR(item, record: record)
                dismiss()
            } catch { errorMessage = SessionLaunchFailure(error: error).message }
        }
    }
}
