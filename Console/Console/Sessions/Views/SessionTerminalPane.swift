import SwiftUI
import SwiftTerm

/// Selected terminal pane: header with name and state, optional compact info
/// strip (summary + artifact chips), and the persistent terminal view.
struct SessionTerminalPane: View {
    let session: ConsoleSession
    let displayedState: DisplayedSessionState
    let onQuickCommand: (String) -> Void
    let onColor: (String) -> Void
    let onTerminate: () -> Void

    /// The Quick Commands configured in Settings. `@AppStorage` observes the
    /// same defaults key the settings window writes, so edits show up here
    /// immediately.
    @AppStorage(AppSettings.quickCommandsKey) private var quickCommandsJSON: String = "[]"
    @AppStorage("webViewJiraURL") private var webViewJiraURL: String = ""

    private var quickCommands: [String] {
        AppSettings.decodeQuickCommands(from: quickCommandsJSON)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if let warning = session.instrumentationWarning {
                SessionInstrumentationWarning(message: warning)
                Divider()
            }

            if showsInfoStrip {
                SessionInfoStrip(session: session)
                Divider()
            }

            TerminalSurface {
                TerminalHost(terminalView: session.terminalView)
            }
        }
    }

    private var showsInfoStrip: Bool {
        session.summary != nil || !infoStripArtifacts.isEmpty
    }

    /// The session's most recent merge-request artifact, rendered as the
    /// tappable header badge. The info strip deliberately excludes it.
    private var mergeRequestArtifact: SessionArtifact? {
        session.artifacts.last { $0.kind == .gitlabMergeRequest }
    }

    private var infoStripArtifacts: [SessionArtifact] {
        session.artifacts.filter { $0.kind != .gitlabMergeRequest }
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
                    .background(Capsule().fill(displayedState.tint.opacity(0.15)))
                    .foregroundStyle(displayedState.tint)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Session \(session.name), \(displayedState.label)")
            .accessibilityIdentifier("Sessions.Header")
            .help(session.workingDirectory.path)

            Spacer()

            mergeRequestBadge

            if let url = HomeStorySessionMatcher.jiraURL(
                for: session, configuredURL: webViewJiraURL, reviewItems: MRReviewScanController.shared.items
            ) {
                Button("Open in JIRA") {
                    JiraDeepLink.shared.set(url: url)
                    ConsoleNavigation.show(.jira)
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("Sessions.OpenInJira")
            }

            quickCommandsMenu

            colorMenu

            Button(action: onTerminate) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Terminate Session")
            .accessibilityLabel("Terminate Session")
            .accessibilityIdentifier("StopSessionButton")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Tappable chip for the session's merge-request artifact: opens the
    /// GitLab destination with the MR in a new browser tab for review.
    /// Memory-only handoff — the URL never leaves the process.
    @ViewBuilder
    private var mergeRequestBadge: some View {
        if let artifact = mergeRequestArtifact {
            Button {
                openMergeRequest(artifact)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.merge")
                        .font(.caption2)
                    Text(artifact.label)
                        .font(.caption)
                        .lineLimit(1)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(Capsule().stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(artifact.url == nil)
            .help("Review this merge request in GitLab")
            .accessibilityLabel("Review \(artifact.label) in GitLab")
            .accessibilityIdentifier("Sessions.MergeRequestBadge")
        }
    }

    /// Queues the MR URL as a new-tab handoff and switches to the GitLab
    /// destination, which consumes it on appear.
    private func openMergeRequest(_ artifact: SessionArtifact) {
        guard let url = artifact.url else { return }
        MergeRequestDeepLink.shared.setNewTab(url: url)
        ConsoleNavigation.show(.mergeRequests)
    }

    /// Quick Commands configured in Settings, rendered as a capsule menu
    /// immediately left of the color picker. Selecting an entry routes through
    /// the shared replacement-and-submit path: the current line is cleared, the
    /// command is inserted, and Return is pressed. Disabled after Claude
    /// exits — there is no prompt left to accept a command.
    private var quickCommandsMenu: some View {
        Menu {
            let commands = quickCommands
            if commands.isEmpty {
                Button("Add commands in Settings.") {}
                    .disabled(true)
                    .accessibilityIdentifier("Sessions.QuickCommand.EmptyState")
            } else {
                ForEach(Array(commands.enumerated()), id: \.offset) { index, command in
                    Button(command) {
                        onQuickCommand(command)
                    }
                    .accessibilityIdentifier("Sessions.QuickCommand.\(index)")
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text("Command")
                    .font(.caption)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(Capsule().stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(session.activity == .exited)
        .help("Replace the current input line and press Return. Clear multiline drafts manually first.")
        .accessibilityLabel("Quick Commands")
        .accessibilityIdentifier("Sessions.QuickCommandsMenu")
    }

    /// Palette for Claude Code's `/color` command. Disabled after Claude
    /// exits — including while the pane sits at its fallback login shell —
    /// because there is no Claude prompt left to accept the command.
    private var colorMenu: some View {
        Menu {
            ForEach(SessionColorOption.all) { option in
                Button {
                    onColor(option.argument)
                } label: {
                    HStack(spacing: 6) {
                        SessionColorSwatch(option: option)
                        Text(option.name)
                    }
                }
                .accessibilityIdentifier("Sessions.Color.\(option.argument)")
            }
        } label: {
            Image(systemName: "square.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.gray)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(session.activity == .exited)
        .help("Set Claude session color — replaces the current input line. Clear multiline drafts manually first.")
        .accessibilityLabel("Set Claude Session Color")
        .accessibilityIdentifier("SessionColorMenu")
    }
}

/// One entry in the session color menu. `argument` is the exact value
/// forwarded to Claude Code's `/color` slash command; `swatch` is nil for
/// the reset entry, which renders as a hollow circle.
struct SessionColorOption: Identifiable, Equatable {
    let name: String
    let argument: String
    let swatch: SwiftUI.Color?

    var id: String { argument }

    static let palette: [SessionColorOption] = [
        SessionColorOption(name: "Red", argument: "red", swatch: .red),
        SessionColorOption(name: "Blue", argument: "blue", swatch: .blue),
        SessionColorOption(name: "Green", argument: "green", swatch: .green),
        SessionColorOption(name: "Yellow", argument: "yellow", swatch: .yellow),
        SessionColorOption(name: "Purple", argument: "purple", swatch: .purple),
        SessionColorOption(name: "Orange", argument: "orange", swatch: .orange),
        SessionColorOption(name: "Pink", argument: "pink", swatch: .pink),
        SessionColorOption(name: "Cyan", argument: "cyan", swatch: .cyan),
    ]
    static let reset = SessionColorOption(name: "Default", argument: "default", swatch: nil)
    static let all = palette + [reset]
}

private struct SessionColorSwatch: View {
    let option: SessionColorOption

    var body: some View {
        if let swatch = option.swatch {
            Circle()
                .fill(swatch)
                .frame(width: 10, height: 10)
        } else {
            Circle()
                .strokeBorder(SwiftUI.Color.secondary, lineWidth: 1)
                .frame(width: 10, height: 10)
        }
    }
}

/// Compact status warning when the session launched without a usable
/// plugin/bridge. The Claude process still runs; activity will not update.
private struct SessionInstrumentationWarning: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("Sessions.BridgeUnavailable")
    }
}

/// Compact strip showing the latest summary/attention message and up to two
/// artifact chips plus an overflow count. Chips are informational only.
/// Merge-request artifacts are excluded: they render as the tappable header
/// badge in `SessionTerminalPane` instead.
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

    private var stripArtifacts: [SessionArtifact] {
        session.artifacts.filter { $0.kind != .gitlabMergeRequest }
    }

    private var chips: [SessionArtifact] {
        Array(stripArtifacts.suffix(Self.maxVisibleChips))
    }

    private var overflowCount: Int {
        max(0, stripArtifacts.count - Self.maxVisibleChips)
    }

    private func icon(for kind: SessionArtifactKind) -> String {
        switch kind {
        case .jiraIssue: return "ticket"
        case .gitlabMergeRequest: return "arrow.triangle.merge"
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
