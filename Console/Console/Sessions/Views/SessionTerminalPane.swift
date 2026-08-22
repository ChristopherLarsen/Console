import SwiftUI
import SwiftTerm

/// Selected terminal pane: header with name and state, optional compact info
/// strip (summary + artifact chips), and the persistent terminal view.
struct SessionTerminalPane: View {
    let session: ConsoleSession
    let displayedState: DisplayedSessionState
    let onRequestStop: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            if showsInfoStrip {
                SessionInfoStrip(session: session)
                Divider()
            }

            TerminalHost(terminalView: session.terminalView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var showsInfoStrip: Bool {
        session.summary != nil || !session.artifacts.isEmpty
    }

    private var header: some View {
        HStack(spacing: 8) {
            // One coherent accessibility element for name and state metadata.
            HStack(spacing: 8) {
                Text(session.name)
                    .font(.headline)
                    .lineLimit(1)

                Text(displayedState.label)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Session \(session.name), \(displayedState.label)")
            .accessibilityIdentifier("Sessions.Header")

            Spacer()

            Button(action: onRequestStop) {
                Image(systemName: "stop.circle")
            }
            .buttonStyle(.plain)
            .help("Stop Session")
            .accessibilityLabel("Stop Session")
            .accessibilityIdentifier("StopSessionButton")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Compact strip showing the latest summary/attention message and up to two
/// artifact chips plus an overflow count. Chips are informational only.
struct SessionInfoStrip: View {
    let session: ConsoleSession

    private static let maxVisibleChips = 2

    var body: some View {
        HStack(spacing: 6) {
            if let summary = session.summary {
                Image(systemName: "text.bubble")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
            }

            Spacer(minLength: 8)

            ForEach(chips) { artifact in
                HStack(spacing: 3) {
                    Image(systemName: icon(for: artifact.kind))
                        .font(.caption2)
                    Text(artifact.label)
                        .font(.caption)
                        .lineLimit(1)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(Capsule().stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                .help("Artifact (informational): \(artifact.label)")
            }

            if overflowCount > 0 {
                Text("+\(overflowCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("Sessions.InfoStrip")
    }

    private var chips: [SessionArtifact] {
        Array(session.artifacts.suffix(Self.maxVisibleChips))
    }

    private var overflowCount: Int {
        max(0, session.artifacts.count - Self.maxVisibleChips)
    }

    private func icon(for kind: SessionArtifactKind) -> String {
        switch kind {
        case .jiraIssue: return "ticket"
        case .gitlabMergeRequest: return "arrow.triangle.pull"
        }
    }
}

/// NSViewRepresentable hosting a session's persistent terminal view. The same
/// instance is returned for the whole session lifetime so process, view, and
/// scrollback survive switching between sessions.
struct TerminalHost: NSViewRepresentable {
    let terminalView: LocalProcessTerminalView

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        DispatchQueue.main.async {
            terminalView.window?.makeFirstResponder(terminalView)
        }
        return terminalView
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
