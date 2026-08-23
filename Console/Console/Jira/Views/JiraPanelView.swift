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
        HomePanelHeader(
            title: "My Tickets",
            detail: {
                if let count = headerCount {
                    HomePanelDetail("JIRA", "\(count)")
                }
            },
            accessory: {
                if controller.isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("Refreshing")
                }

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
        )
        .accessibilityIdentifier("JiraPanelHeader")
    }

    private var headerCount: Int? {
        switch controller.state {
        case let .loaded(tickets, _), let .stale(tickets, _, _):
            return tickets.count
        default:
            return nil
        }
    }

    private func ticketList(_ tickets: [JiraTicketSummary], refreshedAt: Date, staleReason: String?) -> some View {
        VStack(spacing: 0) {
            if let staleReason {
                staleBanner(reason: staleReason, refreshedAt: refreshedAt)
            }

            ScrollView {
                LazyVStack(spacing: HomeCardMetrics.listGap) {
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
            .background(Color(nsColor: .windowBackgroundColor))
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            footerTimestamp(refreshedAt: refreshedAt)
        }
    }

    /// Amber strip naming the age of what you are looking at, plus a way out.
    /// The cards below stay at full strength — they are old, not wrong.
    private func staleBanner(reason: String, refreshedAt: Date) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 9, weight: .medium))
            Text("Showing results from \(refreshedAt.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 10))
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("Retry") {
                controller.refresh()
            }
            .disabled(controller.isRefreshing)
            .accessibilityIdentifier("JiraPanelStaleRetryButton")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .foregroundStyle(Color.orange)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(Color.orange.opacity(0.12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Could not refresh · showing previous results (\(reason))")
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
        VStack(spacing: HomeCardMetrics.listGap) {
            ForEach(0..<4, id: \.self) { index in
                HomeSkeletonCard()
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

/// One ticket on the Home dashboard, drawn to the shared card grammar
/// (Design/HomeCards/DESIGN_PROMPT.md §3): row one is dot + identity + state
/// + age; row two is the title plus a permanently reserved trailing action
/// slot; tickets have no optional third row today.
private struct JiraTicketCard: View {
    let ticket: JiraTicketSummary
    let accessibilityIdentifier: String
    let action: () -> Void
    var onStartSession: (() -> Void)?

    @State private var hovering = false
    /// Vertical center of the title row in the card's own coordinate space;
    /// the session button (a sibling of the card button, never nested inside
    /// it) is centered on this so it can only ever occupy the reserved slot.
    @State private var titleMidY: CGFloat?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: action) {
                cardRows
            }
            .buttonStyle(.plain)
            .focusable(true)
            .focusEffectDisabled(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(cardAccessibilityLabel)
            .accessibilityAction(named: "Open in JIRA", action)
            .accessibilityIdentifier(accessibilityIdentifier)

            // Secondary launch affordance, a sibling of the open button so
            // the card keeps its single primary action. It lives entirely
            // inside the 16pt slot reserved by row two.
            if let onStartSession {
                Button(action: onStartSession) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: HomeCardMetrics.actionSlotWidth)
                }
                .buttonStyle(.plain)
                .frame(height: 18)
                .opacity(hovering ? 1 : 0.3)
                .padding(.top, startButtonTopInset)
                .help("Start a Claude session for this ticket")
                .accessibilityLabel("Start Claude session")
                .accessibilityIdentifier("JiraTicketCard.StartSession")
            }
        }
        .coordinateSpace(name: Self.slotSpace)
        .onPreferenceChange(TitleRowCenterKey.self) { titleMidY = $0 }
        .onHover { hovering = $0 }
    }

    private static let slotSpace = "JiraTicketCardSlot"

    private var cardRows: some View {
        VStack(alignment: .leading, spacing: HomeCardMetrics.rowGap) {
            HStack(spacing: 5) {
                if let caretTint = priorityCaretTint {
                    Image(systemName: "arrowtriangle.up.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(caretTint)
                }

                Circle()
                    .fill(statusChannel.color)
                    .frame(width: 6, height: 6)

                Text(ticket.key)
                    .font(HomeCardMetrics.identityFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)

                if let status = ticket.status {
                    Text(status)
                        .font(HomeCardMetrics.stateFont)
                        .foregroundStyle(statusChannel.color)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                ageText
            }

            Text(ticket.summary)
                .font(HomeCardMetrics.titleFont)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                // Reserve the 16pt action slot plus breathing room, so the
                // title can never run under the session button.
                .padding(.trailing, HomeCardMetrics.actionSlotWidth + 4)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: TitleRowCenterKey.self,
                            value: geometry.frame(in: .named(Self.slotSpace)).midY
                        )
                    }
                }
        }
        .padding(HomeCardMetrics.padding)
        .frame(maxWidth: .infinity, minHeight: HomeCardMetrics.minHeight, alignment: .leading)
        .homeCardSurface(hovering: hovering)
    }

    private var startButtonTopInset: CGFloat {
        let fallback = HomeCardMetrics.padding.top + 7
        return max(HomeCardMetrics.padding.top, (titleMidY ?? fallback) - 9)
    }

    private var statusChannel: AttentionChannel {
        AttentionChannel.forTicketStatus(ticket.status)
    }

    @ViewBuilder
    private var ageText: some View {
        // No updated text at all: omit rather than guess (§6).
        if let age = RelativeAge.compact(from: ticket.updatedText) {
            Text(age)
                .font(HomeCardMetrics.ageFont.monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    /// Priority demoted to a leading caret for High and Highest only. Medium
    /// and below are omitted entirely — twelve rows reading "Low" teach
    /// nothing and the field stops competing for the trailing corner. This is
    /// a deliberate extension of the omit-unavailable-fields rule (§6).
    private var priorityCaretTint: Color? {
        switch ticket.priority?.lowercased() {
        case "highest":
            return .red
        case "high":
            return .orange
        default:
            return nil
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
}

/// The vertical center of the title row, measured so the sibling session
/// button lands exactly in the reserved slot regardless of wrapping or type
/// growth.
private struct TitleRowCenterKey: PreferenceKey {
    static var defaultValue: CGFloat?
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = value ?? nextValue()
    }
}

#Preview("JIRA Panel") {
    JiraPanelView()
        .frame(width: 420, height: 320)
}
