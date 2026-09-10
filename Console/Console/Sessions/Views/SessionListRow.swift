import SwiftUI

/// One row in the session list: name, working-folder basename, displayed
/// state, and unread attention. The select surface is a real button; exited
/// sessions expose a sibling remove button.
struct SessionListRow: View {
    let session: ConsoleSession
    let displayedState: DisplayedSessionState
    let isSelected: Bool
    let onSelect: () -> Void
    let onTerminate: () -> Void
    let onRemove: () -> Void
    let onRename: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    stateDot

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            if let purpose = session.purpose {
                                Image(systemName: purpose.symbolName)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .help(purpose.displayName)
                            }
                            Text(session.name)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                        }

                        Text(session.workingDirectory.lastPathComponent)
                            .font(.caption2)
                            .lineLimit(1)
                            .foregroundStyle(.tertiary)
                            .help(session.workingDirectory.path)

                        Text(displayedState.label)
                            .font(.caption2)
                            .foregroundStyle(stateColor)
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
            .buttonStyle(.plain)
            // One coherent accessibility element for the whole row's metadata.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "\(purposePrefix)\(session.name), \(session.workingDirectory.lastPathComponent), \(displayedState.label)\(showsAttentionBadge ? ", needs attention" : "")"
            )
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            // Generic identifier only: generated names may contain ticket
            // keys or MR numbers that must not leak into AX identifiers.
            .accessibilityIdentifier("SessionRow.\(session.id.uuidString)")

            if showsAttentionBadge {
                AttentionBadge(
                    pointSize: 13,
                    accessibilityLabel: "Needs attention"
                )
            }

            if session.activity == .exited {
                Button {
                    onRemove()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Remove Exited Session")
                .accessibilityLabel("Remove \(session.name)")
                .accessibilityIdentifier("RemoveSessionButton.\(session.id.uuidString)")
            }
        }
        .contextMenu {
            Button("Select", action: onSelect)
            Button("Rename…", action: onRename)
            if session.activity != .exited {
                Button("Terminate…", action: onTerminate)
            } else {
                Button("Remove", action: onRemove)
            }
        }
    }

    private var purposePrefix: String {
        guard let purpose = session.purpose else { return "" }
        return "\(purpose.displayName). "
    }

    private var showsAttentionBadge: Bool {
        switch session.attention {
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
