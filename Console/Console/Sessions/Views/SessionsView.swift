import SwiftUI

/// The Sessions destination: compact session list on the left, selected
/// terminal filling the remaining space.
struct SessionsView: View {
    @Environment(SessionStore.self) private var store
    @State private var showingNewSessionSheet = false
    @State private var pendingStopConfirmationID: UUID?

    static let listWidth: CGFloat = 260

    var body: some View {
        HStack(spacing: 0) {
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

            Divider()

            detailArea
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showingNewSessionSheet) {
            NewClaudeSessionSheet()
        }
        .confirmationDialog(
            stopConfirmationTitle,
            isPresented: stopConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Stop Session", role: .destructive) {
                if let id = pendingStopConfirmationID {
                    store.stopSession(id: id)
                }
                pendingStopConfirmationID = nil
            }
            .accessibilityIdentifier("Sessions.ConfirmStopButton")
            Button("Cancel", role: .cancel) {
                pendingStopConfirmationID = nil
            }
        } message: {
            Text("This session is still active. Stopping will terminate its Claude process.")
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
                Text("The graceful stop timed out. Force Stop kills the process immediately; scrollback is kept.")
            }
        )
    }

    private var listHeader: some View {
        HStack {
            Text("Sessions")
                .font(.headline)
            Spacer()
            Button {
                showingNewSessionSheet = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .help("New Claude Session")
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
                showingNewSessionSheet = true
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
                        onStop: { requestStop(session) },
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
                onRequestStop: { requestStop(session) }
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

    // MARK: - Stop flow

    private func requestStop(_ session: ConsoleSession) {
        let state = displayedSessionState(activity: session.activity, attention: session.attention)
        switch state {
        case .working, .needsApproval, .needsInput:
            pendingStopConfirmationID = session.id
        default:
            store.stopSession(id: session.id)
        }
    }

    private var stopConfirmationTitle: String {
        guard let id = pendingStopConfirmationID,
              let session = store.session(withID: id) else {
            return "Stop Session?"
        }
        return "Stop “\(session.name)”?"
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
    SessionsView()
        .environment(SessionStore())
}
