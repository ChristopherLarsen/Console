import SwiftUI
import WebKit

struct JiraPanelView: View {
    @AppStorage("webViewJiraURL") private var webViewJiraURL: String = ""
    @AppStorage("sidebarSelection") private var sidebarSelection: SidebarSelection = .home
    @State private var controller = JiraWebSession.shared.panelController
    @Environment(SessionLaunchCoordinator.self) private var launchCoordinator
    @FocusState private var browserControlsFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if normalizedURL == nil {
                unconfiguredState
            } else {
                panelContent
            }
        }
        .onAppear {
            controller.configure(url: normalizedURL)
        }
        .onChange(of: webViewJiraURL) {
            controller.configure(url: normalizedURL)
        }
        .onChange(of: controller.showsBrowser) {
            if controller.showsBrowser {
                browserControlsFocused = true
            }
        }
    }


    private var normalizedURL: URL? {
        JiraView.normalizedURL(from: webViewJiraURL)
    }

    private var panelContent: some View {
        ZStack {
            webLayer
            if !controller.showsBrowser {
                cardLayer
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var webLayer: some View {
        VStack(spacing: 0) {
            if controller.showsBrowser {
                compactBrowserControls
            }
            WebView(JiraWebSession.shared.page)
                .webViewBackForwardNavigationGestures(.enabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(controller.showsBrowser)
                .accessibilityHidden(!controller.showsBrowser)
                .accessibilityIdentifier("JiraPanelWebView")
        }
    }

    private var compactBrowserControls: some View {
        HStack(spacing: 10) {
            Button {
                let page = JiraWebSession.shared.page
                if let item = page.backForwardList.backList.last {
                    page.load(item)
                }
            } label: {
                Image(systemName: "chevron.backward")
            }
            .disabled(JiraWebSession.shared.page.backForwardList.backList.isEmpty)
            .help("Back")
            .focused($browserControlsFocused)

            Button {
                let page = JiraWebSession.shared.page
                if let item = page.backForwardList.forwardList.first {
                    page.load(item)
                }
            } label: {
                Image(systemName: "chevron.forward")
            }
            .disabled(JiraWebSession.shared.page.backForwardList.forwardList.isEmpty)
            .help("Forward")

            Button {
                let page = JiraWebSession.shared.page
                if page.isLoading {
                    page.stopLoading()
                } else {
                    page.reload()
                }
            } label: {
                Image(systemName: JiraWebSession.shared.page.isLoading ? "xmark" : "arrow.clockwise")
            }
            .help(JiraWebSession.shared.page.isLoading ? "Stop" : "Reload")

            Spacer()

            if controller.state.hasCards || isPositiveEmpty {
                Button("Show Cards") {
                    controller.showCards()
                }
                .accessibilityIdentifier("JiraPanelShowCardsButton")
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityIdentifier("JiraPanelBrowserControls")
    }

    @ViewBuilder
    private var cardLayer: some View {
        VStack(spacing: 0) {
            panelHeader
            Divider()
            switch controller.state {
            case .unconfigured:
                Color.clear.frame(height: 0)
            case .loadingPage, .extracting:
                loadingBody
            case let .loaded(tickets, refreshedAt):
                ticketList(tickets, refreshedAt: refreshedAt, staleReason: nil)
            case let .stale(tickets, refreshedAt, reason):
                ticketList(tickets, refreshedAt: refreshedAt, staleReason: reason)
            case .empty:
                emptyState
            case .authenticationRequired:
                authenticationNotice
            case .unsupportedPage:
                unsupportedState
            case .extractionFailed:
                failureState
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .allowsHitTesting(true)
    }

    private var isPositiveEmpty: Bool {
        if case .empty = controller.state { return true }
        return false
    }

    private var panelHeader: some View {
        HStack(spacing: 8) {
            Text(headerTitle)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            Text("JIRA")
                .font(.caption)
                .foregroundStyle(.secondary)

            if controller.isRefreshing {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Refreshing")
            }

            Spacer(minLength: 0)

            Button {
                controller.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(controller.isRefreshing || normalizedURL == nil)
            .help("Refresh tickets")
            .accessibilityIdentifier("JiraPanelRefreshButton")

            Button {
                controller.showJIRA()
            } label: {
                Image(systemName: "macwindow.on.rectangle")
            }
            .help("Show JIRA")
            .accessibilityIdentifier("JiraPanelShowJIRAButton")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("JiraPanelHeader")
    }

    private var headerTitle: String {
        switch controller.state {
        case let .loaded(tickets, _):
            return "My Tickets · \(tickets.count) shown"
        case let .stale(tickets, _, _):
            return "My Tickets · \(tickets.count) shown"
        default:
            return "My Tickets"
        }
    }

    private func ticketList(_ tickets: [JiraTicketSummary], refreshedAt: Date, staleReason: String?) -> some View {
        VStack(spacing: 0) {
            if let staleReason {
                staleBanner(reason: staleReason)
            }

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(Array(tickets.enumerated()), id: \.element.id) { index, ticket in
                        JiraTicketCard(
                            ticket: ticket,
                            accessibilityIdentifier: "JiraTicketCard.\(index)",
                            action: {
                                controller.open(ticket)
                            },
                            onStartSession: {
                                launchCoordinator.beginJiraTicketLaunch(
                                    key: ticket.key,
                                    title: ticket.summary.isEmpty ? nil : ticket.summary,
                                    url: ticket.issueURL
                                )
                            }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            footerTimestamp(refreshedAt: refreshedAt)
        }
    }

    private func staleBanner(reason: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.caption2)
            Text("Could not refresh · showing previous results (\(reason))")
                .font(.caption)
                .lineLimit(1)
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(nsColor: .quaternarySystemFill))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("JiraPanelStaleBanner")
    }

    private func footerTimestamp(refreshedAt: Date) -> some View {
        Text("Updated \(refreshedAt.formatted(date: .omitted, time: .shortened))")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .accessibilityIdentifier("JiraPanelFooterTimestamp")
    }

    private var loadingBody: some View {
        VStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .quaternarySystemFill))
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
                    .opacity(index == 3 ? 0.5 : 1)
            }
            Spacer()
        }
        .padding(8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading tickets")
        .accessibilityIdentifier("JiraPanelSkeletons")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No open tickets")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("JiraPanelEmptyState")
    }

    private var authenticationNotice: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text("Sign in to JIRA below")
                .font(.callout.weight(.medium))
            Text("Complete sign-in in the embedded browser. Cards return when the list is available.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("JiraPanelAuthenticationNotice")
    }

    private var unsupportedState: some View {
        VStack(spacing: 8) {
            Image(systemName: "questionmark.square.dashed")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text("Console needs the configured list view")
                .font(.callout.weight(.medium))
                .multilineTextAlignment(.center)
            Button("Show JIRA") {
                controller.showJIRA()
            }
            .accessibilityIdentifier("JiraPanelUnsupportedShowJIRA")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("JiraPanelUnsupportedState")
    }

    private var failureState: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.octagon")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text("Could not read tickets")
                .font(.callout.weight(.medium))
            Button("Show JIRA") {
                controller.showJIRA()
            }
            .accessibilityIdentifier("JiraPanelFailureShowJIRA")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("JiraPanelFailureState")
    }

    private var unconfiguredState: some View {
        VStack(spacing: 10) {
            Image(systemName: "j.square")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Set Web View JIRA URL in Settings")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                sidebarSelection = .settings
            }
            .accessibilityIdentifier("JiraPanelOpenSettings")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("JiraPanelUnconfiguredState")
    }
}

private struct JiraTicketCard: View {
    let ticket: JiraTicketSummary
    let accessibilityIdentifier: String
    let action: () -> Void
    var onStartSession: (() -> Void)?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ticket.key)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                    Spacer(minLength: 4)
                    if let priority = ticket.priority {
                        Text(priority)
                            .font(.caption2)
                            .foregroundStyle(priorityTint)
                    }
                }

                Text(ticket.summary)
                    .font(.footnote.weight(.medium))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let status = ticket.status {
                        Text(status)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color(nsColor: .quaternarySystemFill)))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if let updated = ticket.updatedText {
                        Text(updated)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cardAccessibilityLabel)
        .accessibilityAction(named: "Open in JIRA", action)
        .accessibilityIdentifier(accessibilityIdentifier)

            // Secondary launch affordance, a sibling of the open button so
            // the card keeps its single primary action.
            if let onStartSession {
                Button(action: onStartSession) {
                    Image(systemName: "terminal")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(5)
                        .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(Circle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help("Start a Claude session for this ticket")
                .accessibilityLabel("Start Claude session")
                .accessibilityIdentifier("JiraTicketCard.StartSession")
            }
        }
    }

    private var cardAccessibilityLabel: String {
        var parts: [String] = [ticket.key]
        if !ticket.summary.isEmpty { parts.append(ticket.summary) }
        if let status = ticket.status { parts.append(status) }
        if let priority = ticket.priority { parts.append(priority) }
        if let updated = ticket.updatedText { parts.append(updated) }
        return parts.joined(separator: ", ")
    }

    private var priorityTint: Color {
        switch ticket.priority?.lowercased() {
        case "highest":
            return .red
        case "high":
            return .orange
        default:
            return .secondary
        }
    }
}

#Preview("JIRA Panel") {
    JiraPanelView()
        .frame(width: 420, height: 320)
}
