import SwiftUI

/// Home Panel 2: the live Sessions radar. A compact, attention-sorted list of
/// in-memory Claude sessions backed by the shared `SessionStore`. This is a
/// launcher, not a second Sessions page: no terminal, no stop/remove controls.
/// Clicking a card selects the session and navigates to the Sessions
/// destination where the process, terminal view, and scrollback are alive.
struct HomeSessionsPanelView: View {
    @Environment(SessionStore.self) private var store
    @Environment(SessionLaunchCoordinator.self) private var launchCoordinator
    @State private var showingIntentPicker = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        // The intent picker navigates to Sessions itself after a successful
        // create, so no onCreated hop is needed from Home.
        .popover(isPresented: $showingIntentPicker, arrowEdge: .leading) {
            SessionIntentPickerView()
                .frame(width: 380)
        }
    }

    private var sortedSessions: [ConsoleSession] {
        HomeSessionsPresentation.sorted(store.sessions)
    }

    // MARK: - Header

    /// ```text
    /// Sessions  3 · 1 needs you                     [+]  [window]
    /// ```
    private var header: some View {
        HomePanelHeader(
            title: "Sessions",
            detail: {
                HomePanelDetail("\(store.sessions.count)")

                if needsYouCount > 0 {
                    Text("· \(needsYouCount) needs you")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.red)
                        .lineLimit(1)
                }
            },
            accessory: {
                Button {
                    showingIntentPicker = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("New Claude Session")
                .accessibilityLabel("New Claude Session")
                .accessibilityIdentifier("HomePanelSessions.NewSessionButton")

                Button {
                    ConsoleNavigation.showSessions()
                } label: {
                    Image(systemName: "macwindow.on.rectangle")
                }
                .help("Open Sessions")
                .accessibilityLabel("Open Sessions")
                .accessibilityIdentifier("HomePanelSessions.OpenSessionsButton")
            }
        )
        .accessibilityIdentifier("HomePanelSessions.Header")
    }

    private var needsYouCount: Int {
        HomeSessionsPresentation.needsYouCount(in: store.sessions)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if store.sessions.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: HomeCardMetrics.listGap) {
                    ForEach(sortedSessions) { session in
                        HomeSessionCard(
                            session: session,
                            displayedState: displayedSessionState(
                                activity: session.activity,
                                attention: session.attention
                            )
                        ) {
                            store.select(sessionID: session.id)
                            ConsoleNavigation.showSessions()
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No Claude Sessions")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("New Claude Session") {
                showingIntentPicker = true
            }
            .controlSize(.small)
            .accessibilityIdentifier("HomePanelSessions.EmptyStateNewSessionButton")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("HomePanelSessions.EmptyState")
    }
}

/// One jump target on the Home radar, drawn to the shared card grammar
/// (Design/HomeCards/DESIGN_PROMPT.md §3): row one is the state dot plus its
/// tinted label; row two is the session name in the title slot at the
/// dashboard's fixed x-origin with a reserved trailing slot for the jump
/// chevron; row three merges folder-or-summary (monospace, leading) with the
/// artifact chips (trailing). The whole card is one button; no nested controls.
private struct HomeSessionCard: View {
    let session: ConsoleSession
    let displayedState: DisplayedSessionState
    let action: () -> Void

    @State private var hovering = false

    private var needsYou: Bool {
        HomeSessionsPresentation.needsYou(displayedState)
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: HomeCardMetrics.rowGap) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(displayedState.attentionChannel.color)
                        .frame(width: 6, height: 6)

                    Text(displayedState.label)
                        .font(needsYou ? HomeCardMetrics.stateEmphasisFont : HomeCardMetrics.stateFont)
                        .foregroundStyle(displayedState.attentionChannel.color)
                        .fixedSize()
                        .lineLimit(1)

                    Spacer(minLength: 4)
                }

                HStack(alignment: .top, spacing: 4) {
                    Text(session.name)
                        .font(HomeCardMetrics.titleFont)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 2)

                    // Jump affordance: decoration inside this single card
                    // button, never a nested control.
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor.opacity(hovering ? 1 : 0.3))
                        .homeActionSlot
                }

                contextRow
            }
            .padding(HomeCardMetrics.padding)
            .frame(maxWidth: .infinity, minHeight: HomeCardMetrics.minHeight, alignment: .leading)
            // States that block the agent get a one-point red inset.
            .homeCardSurface(hovering: hovering, alertInset: needsYou ? Color.red : nil)
        }
        .buttonStyle(.plain)
        .focusable(true)
        .focusEffectDisabled(false)
        .onHover { hovering = $0 }
        // One coherent accessibility element for all of the card's metadata.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cardAccessibilityLabel)
        .accessibilityHint("Opens this session on the Sessions page")
        .accessibilityIdentifier("HomeSessionCard.\(session.id.uuidString)")
    }

    /// Folder or summary on the left in monospace, artifact chips
    /// right-aligned; present only when there is something to say.
    @ViewBuilder
    private var contextRow: some View {
        let presentation = HomeSessionsPresentation.artifactChips(for: session)
        if let subtitle = HomeSessionsPresentation.subtitle(for: session) {
            HStack(spacing: 6) {
                Text(subtitle)
                    .font(HomeCardMetrics.identityFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                chips(presentation)
            }
        } else if !presentation.chips.isEmpty || presentation.overflow > 0 {
            HStack(spacing: 6) {
                Spacer(minLength: 4)
                chips(presentation)
            }
        }
    }

    private func chips(_ presentation: (chips: [SessionArtifact], overflow: Int)) -> some View {
        HStack(spacing: 5) {
            ForEach(presentation.chips) { artifact in
                // Filled capsules mean a linked object — a ticket, an MR.
                HStack(spacing: 3) {
                    Image(systemName: icon(for: artifact.kind))
                        .font(.system(size: 8))
                    Text(artifact.label)
                        .font(.system(size: 9))
                        .lineLimit(1)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color(nsColor: .quaternarySystemFill)))
                .help("Artifact (informational): \(artifact.label)")
            }

            if presentation.overflow > 0 {
                Text("+\(presentation.overflow)")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func icon(for kind: SessionArtifactKind) -> String {
        switch kind {
        case .jiraIssue: return "ticket"
        case .gitlabMergeRequest, .githubPullRequest: return "arrow.triangle.pull"
        }
    }

    private var cardAccessibilityLabel: String {
        var parts: [String] = [session.name]
        if let folder = folderSubtitle { parts.append(folder) }
        parts.append(displayedState.label)
        if let summary = session.summary, !summary.isEmpty { parts.append(summary) }
        if needsYou { parts.append("needs attention") }
        return parts.joined(separator: ", ")
    }

    /// The folder basename shown as subtitle when it differs from the name.
    private var folderSubtitle: String? {
        guard session.summary == nil || session.summary!.isEmpty else { return nil }
        let folder = session.workingDirectory.lastPathComponent
        return folder.isEmpty || folder == session.name ? nil : folder
    }
}

#Preview("Sessions Radar") {
    sessionLauncherPreview {
        HomeSessionsPanelView()
            .frame(width: 380, height: 280)
            .padding()
    }
}
