import SwiftUI

struct AboutView: View {
    var onClose: () -> Void

    private let sectionSpacing: CGFloat = 20

    private var appVersion: String? { BuildConfiguration.versionDisplay }

    var body: some View {
        heroSection
    }

    // MARK: - Hero

    private var heroSection: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 128, height: 128)
                .padding(.bottom, 14)

            Text("Console")
                .font(.system(size: 24, weight: .bold, design: .default))
                .padding(.bottom, 4)

            Text("Voice-activated Mac automation")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.bottom, 10)

            if let appVersion {
                Text("Version \(appVersion)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.top, 28)
        .padding(.bottom, sectionSpacing)
        .frame(maxWidth: .infinity)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.5),
            in: UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 12,
                bottomTrailingRadius: 12, topTrailingRadius: 0
            )
        )
    }
}

#Preview {
    AboutView(onClose: {})
}
