import SwiftUI

/// Settings section for Console-managed headless Claude access to JIRA
/// (personal instance only). Surfaces availability and authentication state,
/// offers a connection test (a minimal structured ping — no JIRA access),
/// and a restart that re-validates the installed CLI.
struct ManagedClaudeAccessSection: View {
    @Environment(ManagedClaudeService.self) private var service

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text("JIRA Access")

                    Spacer()

                    stateBadge

                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .textSelection(.enabled)
            }

            HStack(spacing: 16) {
                Button("Test Connection") {
                    Task { await service.testConnection() }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(isBusy)
                .accessibilityIdentifier("Settings.ManagedClaude.TestConnection")

                Button("Reconnect") {
                    Task { await service.restart() }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(isBusy)
                .accessibilityIdentifier("Settings.ManagedClaude.Reconnect")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } header: {
            Text("JIRA Access")
        } footer: {
            Text("Console-run headless Claude operations for personal-instance JIRA tickets, with dedicated sessions and bounded transcript retention. Company JIRA content is DOM-only inside the in-app WebView and is never routed through Claude; that routing stays disabled by policy.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var isBusy: Bool {
        service.state == .busy || service.state == .starting || service.state == .recovering
    }

    private var isBusyForTest: Bool { isBusy }

    private var stateBadge: some View {
        Text(stateLabel)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(statusColor.opacity(0.15)))
            .foregroundStyle(statusColor)
            .accessibilityIdentifier("Settings.ManagedClaude.StateText")
    }

    private var stateLabel: String {
        switch service.state {
        case .stopped: return "Stopped"
        case .starting: return "Starting"
        case .ready: return "Ready"
        case .busy: return "Busy"
        case .needsAuthentication: return "Sign-in required"
        case .recovering: return "Recovering"
        case .error: return "Error"
        }
    }

    private var statusText: String {
        switch service.state {
        case .stopped:
            return "Prepares on first use."
        case .starting:
            return "Locating Claude Code and validating installed CLI flags…"
        case .ready:
            return service.lastTestDescription ?? "Validated. No operations run until a JIRA action needs one."
        case .busy:
            return "Running an operation."
        case .needsAuthentication:
            return "Claude Code needs authentication. Sign in with `claude` in a terminal, then Reconnect."
        case .recovering:
            return "An operation timed out or was interrupted; the service is recovering."
        case .error(let message):
            return service.lastTestDescription ?? message
        }
    }

    private var statusColor: Color {
        switch service.state {
        case .ready: return .green
        case .busy, .starting, .recovering: return .secondary
        case .needsAuthentication, .error, .stopped: return .orange
        }
    }
}

#Preview {
    Form {
        ManagedClaudeAccessSection()
    }
    .environment(ManagedClaudeService(transport: NoopTransport()))
}

private struct NoopTransport: ClaudeHeadlessTransporting {
    func run(_ request: ClaudeHeadlessRequest) async -> ClaudeHeadlessOutcome {
        ClaudeHeadlessOutcome(dispatched: false, stdout: nil, stderr: nil, failure: .launchFailed(reason: "preview"))
    }
}
