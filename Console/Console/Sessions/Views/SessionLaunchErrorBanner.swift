import SwiftUI

/// MainView overlay for contextual launches that failed without an open
/// chooser (missing Claude, vanished folder, launcher throw).
struct SessionLaunchErrorBanner: View {
    let failure: SessionLaunchFailure
    let onDismiss: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.title3)

                Text(failure.message)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                CloseButton(action: onDismiss)
                    .accessibilityIdentifier("Sessions.Launch.DismissError")
            }

            HStack {
                Spacer()
                if failure.offersSettingsRoute {
                    Button("Open Sessions Settings", action: onOpenSettings)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("Sessions.Launch.OpenSettings")
                }
                Button("Dismiss", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(12)
        .frame(maxWidth: 520)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 10, y: 4)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Sessions.Launch.Error")
    }
}
