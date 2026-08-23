import SwiftUI

/// The Sessions destination: selected terminal on the left, compact session
/// list filling the right edge.
struct SessionsView: View {
    @Environment(SessionStore.self) private var store
    @Environment(SessionLaunchCoordinator.self) private var coordinator
    @State private var showingIntentPicker = false
    @State private var pendingStopConfirmationID: UUID?

    static let listWidth: CGFloat = 260

    var body: some View {
        HStack(spacing: 0) {
            detailArea

            Divider()

            VStack(spacing: 0) {
                listHeader
                Divider()
                if store.sessions.isEmpty {
                    emptyList
                } else {
                    sessionList
                }
            }
            .frame(width: Self.listWidth)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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
    }

    private var listHeader: some View {
        HStack {
            Text("Sessions")
                .font(.headline)
            Spacer()
            Button {
                showingIntentPicker = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .help("New Session")
            .accessibilityIdentifier("NewSessionButton")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var emptyList: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No Claude Sessions")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("Sessions.EmptyState")
            Button("New Claude Session") {
                showingIntentPicker = true
            }
            .controlSize(.small)
            .accessibilityIdentifier("EmptyStateNewSessionButton")
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
                        onRemove: { store.removeSession(id: session.id) }
                    )
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var detailArea: some View {
        if let session = store.selectedSession {
            SessionTerminalPane(
                session: session,
                displayedState: displayedSessionState(
                    activity: session.activity,
                    attention: session.attention
                ),
                onTerminate: { requestTerminate(session) },
                onSendStarterPrompt: {
                    _ = coordinator.manuallySendStarterPrompt(to: session.id)
                }
            )
            .id(session.id)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                Text("Start a Claude session to begin")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    return content()
        .environment(store)
        .environment(workspaces)
        .environment(SessionLaunchCoordinator(store: store, workspaceStore: workspaces))
}
