import SwiftUI

/// Home Panel 2: the live Sessions radar. A compact, attention-sorted list of
/// in-memory Claude sessions backed by the shared `SessionStore`. This is a
/// launcher, not a second Sessions page: no terminal, no stop/remove controls.
/// Clicking a card selects the session and navigates to the Sessions
/// destination where the process, terminal view, and scrollback are alive.
struct HomeSessionsPanelView: View {
    @Environment(SessionStore.self) private var store
    @State private var showingNewSessionSheet = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .sheet(isPresented: $showingNewSessionSheet) {
            // After a successful create the sheet has already selected the new
            // session; land on Sessions so the first prompt is typed there.
            NewClaudeSessionSheet(onCreated: { ConsoleNavigation.showSessions() })
        }
    }

    private var sortedSessions: [ConsoleSession] {
        HomeSessionsPresentation.sorted(store.sessions)
    }

    // MARK: - Header

    /// ```text
    /// Sessions · 3   · 1 needs you                [+]  [Open Sessions]
    /// ```
    private var header: some View {
        HStack(spacing: 8) {
            Text(headerTitle)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            if needsYouCount > 0 {
                Text("· \(needsYouCount) needs you")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button {
                showingNewSessionSheet = true
            } label: {
                Image(systemName: "plus")
            }
            .help("New Claude Session")
            .accessibilityLabel("New Claude Session")
            .accessibilityIdentifier("HomePanelSessions.NewSessionButton")

            Button("Open Sessions") {
                ConsoleNavigation.showSessions()
            }
            .help("Open the Sessions page")
            .accessibilityIdentifier("HomePanelSessions.OpenSessionsButton")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("HomePanelSessions.Header")
    }

    private var needsYouCount: Int {
        HomeSessionsPresentation.needsYouCount(in: store.sessions)
    }

    private var headerTitle: String {
        "Sessions · \(store.sessions.count)"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if store.sessions.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
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
                showingNewSessionSheet = true
            }
            .controlSize(.small)
            .accessibilityIdentifier("HomePanelSessions.EmptyStateNewSessionButton")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("HomePanelSessions.EmptyState")
    }
}

/// One jump target on the Home radar: state dot + label, name, optional
/// summary-or-folder subtitle, and up to two informational artifact chips.
/// The whole card is a single button; no nested controls.
private struct HomeSessionCard: View {
    let session: ConsoleSession
    let displayedState: DisplayedSessionState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(displayedState.tint)
                        .frame(width: 8, height: 8)

                    Text(displayedState.label)
                        .font(.caption2)
                        .foregroundStyle(displayedState.tint)
                        .fixedSize()
                        .lineLimit(1)

                    Spacer(minLength: 6)

                    Text(session.name)
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if let subtitle = HomeSessionsPresentation.subtitle(for: session) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                chipRow
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .focusable(true)
        .focusEffectDisabled(false)
        // One coherent accessibility element for all of the card's metadata.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cardAccessibilityLabel)
        .accessibilityHint("Opens this session on the Sessions page")
        .accessibilityIdentifier("HomeSessionCard.\(session.name)")
    }

    @ViewBuilder
    private var chipRow: some View {
        let presentation = HomeSessionsPresentation.artifactChips(for: session)
        if !presentation.chips.isEmpty || presentation.overflow > 0 {
            HStack(spacing: 5) {
                ForEach(presentation.chips) { artifact in
                    HStack(spacing: 3) {
                        Image(systemName: icon(for: artifact.kind))
                            .font(.caption2)
                        Text(artifact.label)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color(nsColor: .quaternarySystemFill)))
                    .help("Artifact (informational): \(artifact.label)")
                }

                if presentation.overflow > 0 {
                    Text("+\(presentation.overflow)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
        }
    }

    private func icon(for kind: SessionArtifactKind) -> String {
        switch kind {
        case .jiraIssue: return "ticket"
        case .gitlabMergeRequest: return "arrow.triangle.pull"
        }
    }

    private var cardAccessibilityLabel: String {
        var parts: [String] = [session.name]
        if let folder = folderSubtitle { parts.append(folder) }
        parts.append(displayedState.label)
        if let summary = session.summary, !summary.isEmpty { parts.append(summary) }
        if HomeSessionsPresentation.needsYou(displayedState) { parts.append("needs attention") }
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
    HomeSessionsPanelView()
        .environment(SessionStore())
        .frame(width: 380, height: 280)
        .padding()
}
