import SwiftUI

/// One row in the session list: name, working-folder basename, displayed
/// state, and unread attention. The select surface is a real button; exited
/// sessions expose a sibling remove button.
struct SessionListRow: View {
    @Environment(SessionStore.self) private var store

    let session: ConsoleSession
    let isSelected: Bool
    let onSelect: () -> Void
    let onTerminate: () -> Void
    let onRemove: () -> Void
    let onRename: () -> Void
    let onAttachGitLab: () -> Void
    let onAttachJira: () -> Void

    /// Store copy of this card's session. Read during `body` so the card
    /// subscribes to activity and attention changes directly.
    private var liveSession: ConsoleSession {
        store.session(withID: session.id) ?? session
    }

    private var displayedState: DisplayedSessionState {
        displayedSessionState(activity: liveSession.activity, attention: liveSession.attention)
    }

    /// macOS does not repaint a Menu or plain Button label when its SwiftUI
    /// content changes, so a card would keep the status it had when the
    /// control was first created. Changing this identity rebuilds the control.
    private var cardControlIdentity: String {
        [
            displayedState.rawValue,
            liveSession.name,
            liveSession.workingDirectory.lastPathComponent,
            mergeRequestLabel ?? "",
        ].joined(separator: "\n")
    }

    var body: some View {
        HStack(spacing: 6) {
            if isSelected {
                // A second click on the active card opens its options menu —
                // the same items a right-click offers.
                Menu {
                    contextMenuItems
                } label: {
                    rowContent
                }
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .id(cardControlIdentity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityRowLabel)
                .accessibilityAddTraits(.isSelected)
                .accessibilityHint("Opens session options")
                .accessibilityIdentifier("SessionRow.\(liveSession.id.uuidString)")
            } else {
                Button(action: onSelect) {
                    rowContent
                }
                .buttonStyle(.plain)
                .id(cardControlIdentity)
                // One coherent accessibility element for the whole row's metadata.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityRowLabel)
                .accessibilityIdentifier("SessionRow.\(liveSession.id.uuidString)")
            }

            if showsAttentionBadge {
                AttentionBadge(
                    pointSize: 13,
                    accessibilityLabel: "Needs attention"
                )
            }

            if liveSession.activity == .exited {
                Button {
                    onRemove()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Remove Exited Session")
                .accessibilityLabel("Remove \(liveSession.name)")
                .accessibilityIdentifier("RemoveSessionButton.\(liveSession.id.uuidString)")
            }
        }
        .contextMenu {
            contextMenuItems
        }
    }

    /// The card surface shared by the select button and the selected card's
    /// options menu. Highlight shows the selection; tapping an already
    /// selected card opens `contextMenuItems` via the wrapping Menu.
    private var rowContent: some View {
        HStack(spacing: 8) {
            stateDot

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if let purpose = liveSession.purpose {
                        Image(systemName: purpose.symbolName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help(purpose.displayName)
                    }
                    Text(liveSession.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }

                if let mergeRequestLabel {
                    Text(mergeRequestLabel)
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("SessionRow.MergeRequest.\(liveSession.id.uuidString)")
                }

                Text(liveSession.workingDirectory.lastPathComponent)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.tertiary)
                    .help(liveSession.workingDirectory.path)

                if let status = displayedState.statusText {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(stateColor)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private var contextMenuItems: some View {
        Group {
            Button("Rename", action: onRename)
            if liveSession.activity != .exited {
                Button("Terminate", action: onTerminate)
            } else {
                Button("Remove", action: onRemove)
            }
            Button("Attach GitLab", action: onAttachGitLab)
                .accessibilityIdentifier("Sessions.AttachGitLab")
            Button("Attach JIRA", action: onAttachJira)
                .accessibilityIdentifier("Sessions.AttachJira")
        }
    }

    /// The session's associated merge request as `MR !<iid>`, from the URL when
    /// it parses, otherwise from the artifact label. Nil when none is attached.
    private var mergeRequestLabel: String? {
        guard let artifact = liveSession.artifacts.last(where: { $0.kind == .gitlabMergeRequest }) else {
            return nil
        }
        if let url = artifact.url, let info = GitLabSourceContext.parseMergeRequest(fromURL: url) {
            return "MR !\(info.iid)"
        }
        if let match = artifact.label.firstMatch(of: /(\d+)/) {
            return "MR !\(match.1)"
        }
        return artifact.label.isEmpty ? nil : artifact.label
    }

    private var accessibilityRowLabel: String {
        let base = "\(purposePrefix)\(liveSession.name)\(mergeRequestLabel.map { ", \($0)" } ?? ""), \(liveSession.workingDirectory.lastPathComponent)"
        let withStatus = displayedState.statusText.map { "\(base), \($0)" } ?? base
        return withStatus + (showsAttentionBadge ? ", needs attention" : "")
    }

    private var purposePrefix: String {
        guard let purpose = liveSession.purpose else { return "" }
        return "\(purpose.displayName). "
    }

    private var showsAttentionBadge: Bool {
        switch liveSession.attention {
        case .permission, .question:
            true
        case .unreadCompletion:
            false
        case .blocked, .needsReview:
            true
        case .none:
            false
        }
    }

    private var stateDot: some View {
        Circle()
            .fill(stateColor)
            .frame(width: 8, height: 8)
    }

    private var stateColor: Color {
        displayedState.tint
    }
}
