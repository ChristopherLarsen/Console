import SwiftUI
import AppKit

/// Native searchable action picker. Filter text is `@State` only — it is
/// never written to UserDefaults or kept as search history.
struct DeveloperActionPicker: View {
    @Environment(DeveloperActionRunner.self) private var runner
    @Environment(SessionStore.self) private var sessionStore
    @Environment(SessionWorkspaceLayoutController.self) private var layout
    @Environment(SessionWorkspaceStore.self) private var workspaceStore
    @Environment(IOSProjectProfileStore.self) private var profileStore
    @Environment(IOSBuildCoordinator.self) private var buildCoordinator
    @Environment(SessionLaunchCoordinator.self) private var launchCoordinator

    @State private var query = ""
    @State private var selectedID: DeveloperActionID = .focusCurrentSession
    @State private var escapeMonitor: Any?
    @FocusState private var searchFocused: Bool

    var body: some View {
        let snapshot = runner.snapshot(hosts: hosts)
        let items = DeveloperActionCatalog.matching(
            DeveloperActionCatalog.items(in: snapshot),
            query: query
        )
        let selected = items.first(where: { $0.id == selectedID }) ?? items.first

        VStack(alignment: .leading, spacing: 12) {
            Text("Developer Actions")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            TextField("Filter actions", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { run(selected, snapshot: snapshot) }
                .onKeyPress(.downArrow) {
                    moveSelection(in: items, offset: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveSelection(in: items, offset: -1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    close()
                    return .handled
                }
                .accessibilityIdentifier("DeveloperActions.Search")

            HStack(alignment: .top, spacing: 12) {
                actionList(items)
                preview(selected)
            }
            .frame(maxHeight: .infinity)

            if let message = runner.lastActionMessage {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("DeveloperActions.Message")
            }

            HStack {
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("DeveloperActions.Cancel")
                Spacer()
                Button("Run") { run(selected, snapshot: snapshot) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected?.isEnabled != true)
                    .accessibilityIdentifier("DeveloperActions.Run")
            }
        }
        .padding(20)
        .frame(minWidth: 540, idealWidth: 560, minHeight: 360)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("DeveloperActions.Picker")
        .onAppear {
            query = ""
            searchFocused = true
            selectedID = items.first?.id ?? .focusCurrentSession
            runner.simulatorModel.refreshDevices()
            installEscapeMonitor()
        }
        .onDisappear {
            removeEscapeMonitor()
            query = ""
        }
        .onChange(of: query) { _, _ in
            if items.contains(where: { $0.id == selectedID }) { return }
            selectedID = items.first?.id ?? .focusCurrentSession
        }
        .onExitCommand { close() }
    }

    private var hosts: DeveloperActionHosts {
        DeveloperActionHosts(
            sessionStore: sessionStore,
            layout: layout,
            workspaceStore: workspaceStore,
            profileStore: profileStore,
            buildCoordinator: buildCoordinator,
            launchCoordinator: launchCoordinator
        )
    }

    private func actionList(_ items: [DeveloperActionItem]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if items.isEmpty {
                    Text("No matching actions.")
                        .foregroundStyle(.secondary)
                        .padding(8)
                } else {
                    ForEach(items) { item in
                        Button {
                            selectedID = item.id
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.body)
                                    .foregroundStyle(item.isEnabled ? Color.primary : Color.secondary)
                                if let reason = item.disabledReason {
                                    Text(reason)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(item.id == selectedID ? Color.accentColor.opacity(0.14) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(false)
                        .accessibilityLabel(item.title)
                        .accessibilityValue(item.isEnabled ? "Available" : (item.disabledReason ?? "Unavailable"))
                        .accessibilityAddTraits(item.id == selectedID ? [.isSelected] : [])
                        .accessibilityIdentifier("DeveloperActions.Row.\(item.id.rawValue)")
                    }
                }
            }
        }
        .frame(minWidth: 240)
        .accessibilityIdentifier("DeveloperActions.List")
    }

    private func preview(_ item: DeveloperActionItem?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item?.title ?? "Select an action")
                .font(.subheadline.weight(.semibold))
            if let item {
                ForEach(Array(item.preview.lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .accessibilityIdentifier("DeveloperActions.Preview")
    }

    private func moveSelection(in items: [DeveloperActionItem], offset: Int) {
        guard !items.isEmpty else { return }
        let current = items.firstIndex(where: { $0.id == selectedID }) ?? 0
        let next = min(max(current + offset, 0), items.count - 1)
        selectedID = items[next].id
    }

    private func run(_ item: DeveloperActionItem?, snapshot: DeveloperActionSnapshot) {
        guard let item, item.isEnabled else { return }
        Task { @MainActor in
            await runner.perform(item.id, snapshot: snapshot, hosts: hosts)
            if runner.lastActionMessage == nil {
                close()
            }
        }
    }

    private func close() {
        query = ""
        removeEscapeMonitor()
        runner.dismissPicker()
    }

    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        let runner = self.runner
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                Task { @MainActor in
                    runner.dismissPicker()
                }
                return nil
            }
            return event
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }
}
