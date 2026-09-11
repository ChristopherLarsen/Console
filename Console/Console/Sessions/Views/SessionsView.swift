import SwiftUI

/// The Sessions destination: selected terminal on the left, compact session
/// list filling the right edge. The list is resizable and toggled from the
/// window toolbar; when hidden it unmounts completely so the terminal gets
/// the full width. Focus Session hides it together with the global drawer
/// without killing either terminal process.
struct SessionsView: View {
    @Environment(SessionStore.self) private var store
    @Environment(SessionWorkspaceLayoutController.self) private var layout
    @State private var showingIntentPicker = false
    @State private var pendingStopConfirmationID: UUID?
    @State private var pendingRenameID: UUID?
    @State private var renameText = ""
    @State private var listResizeStartWidth: CGFloat = SessionWorkspaceLayout.listIdealWidth
    @State private var isResizingList = false

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    headlessCards
                    detailArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                    .frame(minWidth: SessionWorkspaceLayout.detailMinWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if layout.showsSessionList {
                    listResizeHandle(availableWidth: geometry.size.width)
                    listColumn
                        .frame(width: layout.listWidth)
                }
            }
            .animation(TerminalPanelView.collapseAnimation, value: layout.showsSessionList)
            .animation(TerminalPanelView.collapseAnimation, value: layout.isFocusMode)
            .onAppear {
                layout.relayout(availableWidth: geometry.size.width)
                if let id = store.selectedSessionID {
                    store.acknowledgeCompletion(sessionID: id)
                }
            }
            .onChange(of: geometry.size.width) { _, newWidth in
                layout.relayout(availableWidth: newWidth)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            repeat {
                await store.refreshHeadlessSessions()
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
            } while !Task.isCancelled
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                toggleListButton
            }
        }
        .popover(isPresented: $showingIntentPicker, arrowEdge: .leading) {
            SessionIntentPickerView()
        }
        .confirmationDialog(
            terminateConfirmationTitle,
            isPresented: stopConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Terminate Session", role: .destructive) {
                if let id = pendingStopConfirmationID {
                    store.terminateSession(id: id)
                }
                pendingStopConfirmationID = nil
            }
            .accessibilityIdentifier("Sessions.ConfirmStopButton")
            Button("Cancel", role: .cancel) {
                pendingStopConfirmationID = nil
            }
        } message: {
            Text("This session is still active. Terminating ends its Claude process and closes the terminal.")
                .accessibilityIdentifier("Sessions.StopConfirmation")
        }
        .alert(
            "Claude did not exit",
            isPresented: forceStopBinding,
            actions: {
                Button("Force Stop", role: .destructive) {
                    if let id = store.awaitingForceStopSessionID {
                        store.forceStop(id: id)
                    }
                }
                Button("Wait", role: .cancel) {}
            },
            message: {
                Text("The graceful termination timed out. Force Stop kills the process immediately; the session then closes.")
            }
        )
        .alert("Rename Session", isPresented: Binding(
            get: { pendingRenameID != nil },
            set: { if !$0 { pendingRenameID = nil } }
        )) {
            TextField("Session name", text: $renameText)
                .accessibilityIdentifier("Sessions.RenameField")
            Button("Rename") {
                if let id = pendingRenameID {
                    store.renameSession(id: id, name: renameText)
                }
                pendingRenameID = nil
            }
            .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {
                pendingRenameID = nil
            }
        }
        .onChange(of: store.selectedSessionID) { _, newID in
            if let newID {
                store.acknowledgeCompletion(sessionID: newID)
            }
            if newID == nil, layout.isFocusMode {
                layout.toggleFocusSession()
            }
            store.focusSelectedTerminal()
        }
    }

    @ViewBuilder
    private var headlessCards: some View {
        if !store.headlessSessions.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Headless Sessions").font(.headline)
                    ForEach(store.headlessSessions) { headless in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(headless.record.name, systemImage: "terminal")
                                    .font(.headline)
                                Spacer()
                                Text("PID \(headless.id.pid)").font(.caption.monospacedDigit())
                            }
                            Text(headless.record.workingDirectory.path)
                                .font(.caption).lineLimit(1).truncationMode(.middle)
                                .help(headless.record.workingDirectory.path)
                            Text("Claude is running without a Console terminal.")
                                .font(.caption)
                            HStack {
                                Button("Kill Session", role: .destructive) {
                                    Task { await store.recoverHeadlessSession(headless, reattach: false) }
                                }
                                .accessibilityIdentifier("Sessions.Headless.Kill.\(headless.id.pid)")
                                Button("Re-attach") {
                                    Task { await store.recoverHeadlessSession(headless, reattach: true) }
                                }
                                .accessibilityIdentifier("Sessions.Headless.Reattach.\(headless.id.pid)")
                                .help("Stops the leftover process and resumes its saved conversation in a new terminal. In-progress work is interrupted.")
                                if store.headlessActionID == headless.id {
                                    ProgressView().controlSize(.small)
                                }
                            }
                            .disabled(store.headlessActionID != nil || store.isRestoringSessions)
                            Text("Re-attach restarts Claude using the saved conversation.")
                                .font(.caption2)
                        }
                        .padding(12)
                        .foregroundStyle(Color.black.opacity(0.85))
                        .background(Color(red: 1, green: 0.94, blue: 0.96), in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("Sessions.Headless.Card.\(headless.id.pid)")
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 240)
        }
    }

    private var restorationFooter: some View {
        VStack(spacing: 6) {
            if let message = store.headlessMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let message = store.restorationPersistenceError ?? store.restorationMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .help(message)
            }
            Button("Restore Sessions") {
                Task { await store.restoreSessions() }
            }
            .buttonStyle(.plain)
            .foregroundStyle(store.canRestoreSessions ? Color.black : Color(nsColor: .lightGray))
            .disabled(!store.canRestoreSessions)
            .accessibilityIdentifier("Sessions.RestoreButton")
            .help(store.isRestoringSessions ? "Restoring sessions…" : "Resume sessions from before Console quit")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var listColumn: some View {
        VStack(spacing: 0) {
            listHeader
            Divider()
            if store.sessions.isEmpty {
                emptyList
            } else {
                sessionList
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Sessions.List")
    }

    private var listHeader: some View {
        HStack {
            Text("Sessions")
                .font(.headline)

            Button {
                showingIntentPicker = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .help("New Session")
            .accessibilityLabel("New Session")
            .accessibilityIdentifier("NewSessionButton")

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Window-toolbar toggle for the session list. Mounted only while the
    /// Sessions destination is active, so it never clutters other pages.
    private var toggleListButton: some View {
        Button {
            layout.isListVisible.toggle()
        } label: {
            Image(systemName: "sidebar.trailing")
                .foregroundStyle(layout.showsSessionList ? Color.accentColor : .secondary)
        }
        .disabled(layout.isFocusMode)
        .help(layout.showsSessionList ? "Hide Session List" : "Show Session List")
        .accessibilityLabel(layout.showsSessionList ? "Hide Session List" : "Show Session List")
        .accessibilityValue(layout.showsSessionList ? "On" : "Off")
        .accessibilityIdentifier("Sessions.ToggleListButton")
    }

    private func listResizeHandle(availableWidth: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if !isResizingList {
                            isResizingList = true
                            listResizeStartWidth = layout.listWidth
                        }
                        let proposed = listResizeStartWidth - value.translation.width
                        layout.applyListWidth(proposed, availableWidth: availableWidth)
                    }
                    .onEnded { _ in
                        isResizingList = false
                    }
            )
            .help("Drag to resize session list")
            .accessibilityHidden(true)
    }

    private var emptyList: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No Sessions")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("Sessions.EmptyState")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(store.sessions) { session in
                    SessionListRow(
                        session: session,
                        displayedState: displayedSessionState(
                            activity: session.activity,
                            attention: session.attention
                        ),
                        isSelected: session.id == store.selectedSessionID,
                        onSelect: { store.select(sessionID: session.id) },
                        onTerminate: { requestTerminate(session) },
                        onRemove: { store.removeSession(id: session.id) },
                        onRename: {
                            renameText = session.name
                            pendingRenameID = session.id
                        }
                    )
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var detailArea: some View {
        VStack(spacing: 0) {
            if let session = store.selectedSession {
                SessionTerminalPane(
                    session: session,
                    displayedState: displayedSessionState(
                        activity: session.activity,
                        attention: session.attention
                    ),
                    onQuickCommand: { command in
                        store.sendSlashCommand(command, to: session.id)
                        store.focusSelectedTerminal()
                    },
                    onColor: { argument in
                        store.sendColorCommand(argument, to: session.id)
                        store.focusSelectedTerminal()
                    },
                    onTerminate: { requestTerminate(session) }
                )
                .id(session.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            restorationFooter
        }
    }

    // MARK: - Terminate flow

    private func requestTerminate(_ session: ConsoleSession) {
        let state = displayedSessionState(activity: session.activity, attention: session.attention)
        switch state {
        case .working, .needsApproval, .needsInput:
            pendingStopConfirmationID = session.id
        default:
            store.terminateSession(id: session.id)
        }
    }

    private var terminateConfirmationTitle: String {
        guard let id = pendingStopConfirmationID,
              let session = store.session(withID: id) else {
            return "Terminate Session?"
        }
        return "Terminate “\(session.name)”?"
    }

    private var stopConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingStopConfirmationID != nil },
            set: { newValue in
                if !newValue {
                    pendingStopConfirmationID = nil
                }
            }
        )
    }

    private var forceStopBinding: Binding<Bool> {
        Binding(
            get: { store.awaitingForceStopSessionID != nil },
            set: { newValue in
                if !newValue {
                    store.dismissForceStopOffer()
                }
            }
        )
    }
}

#Preview("Zero Sessions") {
    sessionLauncherPreview { SessionsView() }
}

/// Shared preview environment: sessions plus launcher dependencies.
@MainActor
func sessionLauncherPreview(@ViewBuilder content: () -> some View) -> some View {
    let store = SessionStore()
    let workspaces = SessionWorkspaceStore()
    let layout = SessionWorkspaceLayoutController()
    return content()
        .environment(store)
        .environment(workspaces)
        .environment(SessionLaunchCoordinator(store: store, workspaceStore: workspaces))
        .environment(layout)
}
