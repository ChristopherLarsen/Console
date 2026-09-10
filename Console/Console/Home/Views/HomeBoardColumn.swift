import SwiftUI

/// One column of the Home work board: fixed header, then either the column's
/// cards or its source-state presentation. Each column scrolls independently;
/// the board never caps or paginates.
struct HomeBoardColumn<Accessory: View, Content: View>: View {
    let title: String
    /// Quiet detail run after the title (service, count); nil renders nothing.
    var detail: String?
    let health: HomeBoardHealth
    /// Recovery card for unconfigured / sign-in / cannot-check states; nil
    /// for sources that have nothing to recover into.
    var recovery: HomeBoardRecovery?
    var onRecovery: (() -> Void)?
    /// What to render when `health.retainsContent`. Empty lists render their
    /// own placeholder cards.
    @ViewBuilder var content: () -> Content
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(spacing: 0) {
            HomePanelHeader(
                title: title,
                detail: {
                    if let detail {
                        HomePanelDetail(detail)
                    }
                },
                accessory: accessory
            )

            ScrollView {
                LazyVStack(spacing: HomeCardMetrics.listGap) {
                    if health.retainsContent {
                        content()
                    } else {
                        statePresentation
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var statePresentation: some View {
        switch health {
        case .ready, .updating, .stale:
            EmptyView()
        case .loading:
            HomeSkeletonCard()
            HomeSkeletonCard()
        case .unconfigured, .signedOut, .unavailable:
            if let recovery {
                HomeBoardRecoveryCard(recovery: recovery, action: { onRecovery?() })
            }
        }
    }
}

/// The kind of recovery card a source state needs, shared by all columns.
enum HomeBoardRecovery: Equatable {
    case setUpJira
    case setUpGitLab
    case signInJira
    case signInGitLab
    case openJira
    case openGitLab

    var title: String {
        switch self {
        case .setUpJira: return HomeBoardSource.jira.setUpCopy
        case .setUpGitLab: return HomeBoardSource.gitlab.setUpCopy
        case .signInJira: return HomeBoardSource.jira.signInCopy
        case .signInGitLab: return HomeBoardSource.gitlab.signInCopy
        case .openJira: return HomeBoardSource.jira.openToContinueCopy
        case .openGitLab: return HomeBoardSource.gitlab.openToContinueCopy
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .setUpJira, .setUpGitLab: return "HomeSourceSetup"
        case .signInJira, .signInGitLab: return "HomeSourceAuthentication"
        case .openJira, .openGitLab: return "HomeSourceOpen"
        }
    }
}

/// Quiet single-button card shown when a source cannot be checked: set-up,
/// sign-in, or open-to-continue. §4.4 — informative, never failure language.
struct HomeBoardRecoveryCard: View {
    let recovery: HomeBoardRecovery
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: HomeCardMetrics.rowGap) {
                Text(recovery.title)
                    .font(HomeCardMetrics.titleFont)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(HomeCardMetrics.padding)
            .frame(maxWidth: .infinity, minHeight: HomeCardMetrics.minHeight, alignment: .leading)
        }
        .buttonStyle(.plain)
        .homeCardSurface(hovering: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(recovery.title)
        .accessibilityIdentifier(recovery.accessibilityIdentifier)
    }
}

/// Non-interactive quiet card for a genuine empty slot or column.
struct HomeBoardPlaceholderCard: View {
    let title: String
    var detail: String?
    var accessibilityIdentifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: HomeCardMetrics.rowGap) {
            Text(title)
                .font(HomeCardMetrics.titleFont)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(HomeCardMetrics.padding)
        .frame(maxWidth: .infinity, minHeight: HomeCardMetrics.minHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HomeCardMetrics.cornerRadius)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.10), radius: 4, x: 0, y: 2)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/// One story card on the board: parked (next story) or active (in progress).
/// One button for the whole card; the reserved action row names the journey.
struct HomeBoardTicketCard: View {
    let ticket: JiraTicketSummary
    /// Verbatim host status shown as tinted state text. The In Progress
    /// column passes nil — the column title already says it.
    let stateLine: String?
    let actionLabel: String
    /// Launch in flight; the action row reads "Starting…" and stays inert.
    var isLaunching = false
    let action: () -> Void

    @State private var hovering = false

    private var channel: AttentionChannel {
        AttentionChannel.forTicketStatus(ticket.status)
    }

    private var actionIsEnabled: Bool { !isLaunching }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: HomeCardMetrics.rowGap) {
                HStack(spacing: 5) {
                    HomeCardGlyph(color: channel.color, needsYou: false)

                    Text(ticket.key)
                        .font(HomeCardMetrics.identityFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let stateLine {
                        Text(stateLine)
                            .font(HomeCardMetrics.stateFont)
                            .foregroundStyle(channel.color)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)
                }

                Text(ticket.summary)
                    .font(HomeCardMetrics.titleFont)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 3) {
                    Spacer(minLength: 0)
                    Text(actionLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(HomeCardMetrics.padding)
            .frame(maxWidth: .infinity, minHeight: HomeCardMetrics.minHeight, alignment: .leading)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .homeCardSurface(hovering: hovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("HomeBoardTicketCard")
    }

    private var accessibilityLabel: String {
        [
            ticket.key,
            ticket.summary,
            stateLine,
            actionLabel,
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}

/// One review-request card: grey dot, normalized author-owes state, project
/// and identity, title. Grey dot even though the state text is red — red dots
/// are reserved for needs-you sessions; Console cannot confirm who reviewed.
struct HomeBoardReviewRequestCard: View {
    let item: MergeRequestSummary
    /// Normalized "Changes requested" / "Discussion" label.
    let stateLabel: String
    let actionLabel: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: HomeCardMetrics.rowGap) {
                HStack(spacing: 5) {
                    HomeCardGlyph(color: .gray, needsYou: false)

                    if let iid = item.iidText {
                        Text("!\(iid)")
                            .font(HomeCardMetrics.identityFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Text(stateLabel)
                        .font(HomeCardMetrics.stateFont)
                        .foregroundStyle(AttentionChannel.needsYou.color)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if let age = RelativeAge.compact(from: item.updatedText) {
                        Text(age)
                            .font(HomeCardMetrics.ageFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Text(item.title)
                    .font(HomeCardMetrics.titleFont)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let project = item.projectDisplayName {
                    Text(project)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 3) {
                    Spacer(minLength: 0)
                    Text(actionLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(HomeCardMetrics.padding)
            .frame(maxWidth: .infinity, minHeight: HomeCardMetrics.minHeight, alignment: .leading)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .homeCardSurface(hovering: hovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("HomeBoardReviewCard")
    }

    private var accessibilityLabel: String {
        [
            item.iidText.map { "MR !\($0)" },
            item.title,
            stateLabel,
            actionLabel,
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}
