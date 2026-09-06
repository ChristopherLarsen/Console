import SwiftUI

/// Warning shown before a second editing session would share one checkout.
/// Offers Focus Existing Session, Continue in Same Folder, or Cancel.
/// Never resets, stashes, switches branches, or kills occupants.
struct SharedCheckoutWarningSheet: View {
    let warning: PendingSharedCheckoutWarning

    @Environment(SessionLaunchCoordinator.self) private var coordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("This folder is already in use")
                    .font(.headline)
                Text("Another live session is editing the same checkout. Continuing keeps uncommitted files as they are and does not stop the existing session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            gitStateSection

            if !warning.occupants.isEmpty {
                occupantList
            }

            if let error = coordinator.lastFailureMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("Sessions.SharedCheckout.Error")
            }

            HStack {
                Button("Cancel") {
                    coordinator.cancelSharedCheckoutWarning()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("Sessions.SharedCheckout.Cancel")

                Spacer()

                Button("Focus Existing Session") {
                    coordinator.focusExistingSession()
                }
                .disabled(!warning.canFocusExisting)
                .accessibilityIdentifier("Sessions.SharedCheckout.Focus")

                Button("Continue in Same Folder") {
                    Task { @MainActor in
                        _ = try? await coordinator.continueInSameFolder()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("Sessions.SharedCheckout.Continue")
            }
        }
        .padding(20)
        .frame(width: 460)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Sessions.SharedCheckout.Warning")
    }

    private var gitStateSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(warning.gitState.branchDisplay)
                .font(.subheadline.weight(.medium))
                .accessibilityIdentifier("Sessions.SharedCheckout.Branch")
            if !warning.gitState.workingTreeDisplay.isEmpty {
                Text(warning.gitState.workingTreeDisplay)
                    .font(.caption)
                    .foregroundStyle(warning.gitState.isDirty ? Color.orange : .secondary)
                    .accessibilityIdentifier("Sessions.SharedCheckout.Dirty")
            }
            Text(warning.canonicalPath)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .truncationMode(.middle)
                .accessibilityIdentifier("Sessions.SharedCheckout.Path")
        }
    }

    private var occupantList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Existing sessions")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            ForEach(warning.occupants) { occupant in
                Button {
                    if occupant.isLiveSession {
                        coordinator.updatePendingCollisionOccupant(occupant.id)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: selectionIcon(for: occupant))
                            .foregroundStyle(isSelected(occupant) ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(occupant.name)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.primary)
                            if let purpose = occupant.purpose {
                                Text(purpose.displayName)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isSelected(occupant) ? Color.accentColor.opacity(0.15) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!occupant.isLiveSession)
                .accessibilityIdentifier("Sessions.SharedCheckout.Occupant")
            }
        }
    }

    private func isSelected(_ occupant: SharedCheckoutOccupant) -> Bool {
        occupant.isLiveSession && occupant.id == warning.focusedOccupantID
    }

    private func selectionIcon(for occupant: SharedCheckoutOccupant) -> String {
        isSelected(occupant) ? "largecircle.fill.circle" : "circle"
    }
}
