import SwiftUI

/// The full-width Next card in the Next destination. Shows "Check" until
/// asked; then picks the next task locally from live panel snapshots and
/// renders it. Tapping the ready card takes the user straight to that work.
struct NextTaskCardView: View {
    @Binding var selection: SidebarSelection

    /// Content-hugging floor for the full-width panel (Christopher's spec).
    static let minimumHeight: CGFloat = 150

    @Environment(SessionStore.self) private var sessionStore: SessionStore?
    @State private var model = NextButtonModel()

    var body: some View {
        cardBody
            .frame(minHeight: Self.minimumHeight)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(
                        colors: [Color.Theme.accentLight, Color.Theme.accentDark],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("NextTaskCard")
    }

    // MARK: - Body states

    @ViewBuilder
    private var cardBody: some View {
        switch model.status {
        case .idle:
            Button { runCheck() } label: { idleContent }
                .buttonStyle(.plain)

        case .checking:
            checkingContent

        case .failed(let message):
            Button { runCheck() } label: {
                VStack(alignment: .leading, spacing: 8) {
                    titleRow()
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    footnote("Tap to retry")
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .buttonStyle(.plain)

        case .ready(let task, let fromAI):
            Button { navigate(task) } label: { readyContent(task, fromAI: fromAI) }
                .buttonStyle(.plain)
        }
    }

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleRow()
            Spacer(minLength: 0)
            Text("Check")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
            Text("Ask what to focus on next.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var checkingContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            titleRow(showSpinner: true)
            Spacer(minLength: 0)
            Text("Checking…")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Reviewing MRs, sessions, and tickets.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("NextTaskChecking")
    }

    private func readyContent(_ task: NextTask, fromAI: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            titleRow(trailingRefresh: true)

            Text(task.headline)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(task.lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 0)

            HStack {
                footnote(navigationHint(for: task))
                Spacer()
                Text(fromAI ? "AI" : "local")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("NextTaskReady")
    }

    // MARK: - Pieces

    private func titleRow(showSpinner: Bool = false, trailingRefresh: Bool = false) -> some View {
        HStack {
            Text("Next")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
            if showSpinner {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            }
            if trailingRefresh {
                refreshButton
            }
        }
    }

    private var refreshButton: some View {
        Button {
            runCheck()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .padding(5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Check again")
        .accessibilityIdentifier("NextTaskRefreshButton")
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.6))
            .lineLimit(1)
    }

    // MARK: - Actions

    private func runCheck() {
        model.check(
            sessionStore: sessionStore ?? SessionStore(),
            jiraController: JiraWebSession.shared.panelController
        )
    }

    private func navigate(_ task: NextTask) {
        switch task.kind {
        case .reviewMergeRequest, .addressComments:
            if let url = task.targetURL {
                let kind: CodeHostListKind = task.kind == .reviewMergeRequest
                    ? .reviewsRequested
                    : .authored
                MergeRequestDeepLink.shared.set(url: url, kind: kind)
                selection = .mergeRequests
            } else {
                fallthroughToSessions(task)
            }

        case .sessionAttention:
            fallthroughToSessions(task)

        case .newTicket:
            selection = .jira
        }
    }

    private func fallthroughToSessions(_ task: NextTask) {
        if let name = task.sessionName,
           let sessionStore,
           let session = sessionStore.sessions.first(where: { $0.name == name }) {
            sessionStore.select(sessionID: session.id)
        }
        ConsoleNavigation.showSessions()
    }

    private func navigationHint(for task: NextTask) -> String {
        switch task.kind {
        case .reviewMergeRequest, .addressComments:
            return "Tap to open GitLab"
        case .sessionAttention:
            return "Tap to open session"
        case .newTicket:
            return "Tap to open JIRA"
        }
    }

    private var accessibilityLabel: String {
        switch model.status {
        case .idle:
            return "Next — check what to do"
        case .checking:
            return "Next — checking"
        case .failed(let message):
            return "Next failed. \(message)"
        case .ready(let task, _):
            let lines = task.lines.joined(separator: ", ")
            return "Next — \(task.headline). \(lines)."
        }
    }
}

#Preview("Idle") {
    @Previewable @State var selection: SidebarSelection = .home
    NextTaskCardView(selection: $selection)
        .environment(SessionStore())
        .frame(width: 560)
        .padding()
}
