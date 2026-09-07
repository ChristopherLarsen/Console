import SwiftUI

/// The full-width Next card in the Next destination. Renders the destination's
/// shared `NextButtonModel`. Refresh and Open are sibling controls — Refresh
/// never navigates; Open (the ready result) does.
struct NextTaskCardView: View {
    @Binding var selection: SidebarSelection
    var model: NextButtonModel
    var onRefresh: () -> Void

    /// Content-hugging floor for the full-width panel (Christopher's spec).
    static let minimumHeight: CGFloat = 150

    @Environment(SessionStore.self) private var sessionStore: SessionStore?

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
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("NextTaskCard")
    }

    // MARK: - Body states

    @ViewBuilder
    private var cardBody: some View {
        switch model.status {
        case .idle:
            Button(action: onRefresh) { idleContent }
                .buttonStyle(.plain)
                .accessibilityLabel("Check next task")
                .accessibilityIdentifier("NextTaskCheckButton")

        case .checking:
            checkingContent

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                titleRow(trailingRefresh: true)
                Button(action: onRefresh) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        footnote("Tap to retry")
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retry next task. \(message)")
                .accessibilityIdentifier("NextTaskRetryButton")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)

        case .ready(let task, let fromAI):
            VStack(alignment: .leading, spacing: 7) {
                titleRow(trailingRefresh: true)

                Button { openReadyTask() } label: {
                    readyOpenContent(task, fromAI: fromAI)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(openAccessibilityLabel(for: task))
                .accessibilityIdentifier("NextTaskOpenButton")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("NextTaskReady")
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("NextTaskChecking")
    }

    private func readyOpenContent(_ task: NextTask, fromAI: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
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

            if let freshnessNote = task.freshnessNote {
                Text(freshnessNote)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .accessibilityLabel(freshnessNote)
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
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
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
        Button(action: onRefresh) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .padding(8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Check again")
        .disabled(model.isChecking)
        .accessibilityLabel("Refresh next task")
        .accessibilityIdentifier("NextTaskRefreshButton")
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.6))
            .lineLimit(1)
    }

    // MARK: - Actions

    private func openReadyTask() {
        if let destination = model.performOpen(sessionStore: sessionStore) {
            selection = destination
        }
    }

    private func navigationHint(for task: NextTask) -> String {
        switch task.resolvedOpenTarget {
        case .mergeRequest:
            return "Tap to open this merge request"
        case .jiraIssue:
            return "Tap to open this issue"
        case .session:
            return "Tap to open session"
        case .ticketWorkflow:
            return "Tap to open Ticket Work"
        case .source(.reviews), .source(.authored):
            return "Tap to open GitLab"
        case .source(.jira):
            return "Tap to open JIRA"
        case .source(.sessions):
            return "Tap to open Sessions"
        }
    }

    private func openAccessibilityLabel(for task: NextTask) -> String {
        let lines = task.lines.joined(separator: ", ")
        return "Open next task. \(task.headline). \(lines)."
    }
}

#Preview("Idle") {
    @Previewable @State var selection: SidebarSelection = .home
    NextTaskCardView(selection: $selection, model: NextButtonModel(), onRefresh: {})
        .environment(SessionStore())
        .frame(width: 560)
        .padding()
}
