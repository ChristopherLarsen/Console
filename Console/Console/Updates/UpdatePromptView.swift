import SwiftUI

/// App-level prompt shown when a qualifying release is offered.
/// "Later" suppresses the release for the current process; "Update" starts
/// the source checkout.
struct UpdatePromptView: View {

    let currentVersion: SemanticVersion?
    let release: GitHubRelease
    let onLater: () -> Void
    let onUpdate: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
                .accessibilityIdentifier("UpdatePrompt.Icon")

            VStack(spacing: 6) {
                Text(titleText)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("UpdatePrompt.Title")

                Text(detailText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("UpdatePrompt.Message")
            }

            Text("Console downloads the source for this version. You then build the Release configuration yourself in Xcode — nothing is installed automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            HStack(spacing: 12) {
                Button("Later", action: onLater)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("UpdatePrompt.LaterButton")

                Button("Update", action: onUpdate)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("UpdatePrompt.UpdateButton")
            }
        }
        .padding(28)
        .frame(width: 420)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 24, y: 8)
    }

    private var titleText: String {
        let newVersion = release.semanticVersion?.displayString ?? release.tagName
        return "Console \(newVersion) is available"
    }

    private var detailText: String {
        if let currentVersion {
            return "You are running Console \(currentVersion.displayString)."
        }
        return "A newer version of Console is available."
    }
}
