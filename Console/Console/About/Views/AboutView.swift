import SwiftUI

struct AboutView: View {
    var onClose: () -> Void

    private let sectionSpacing: CGFloat = 20

    private var appVersion: String? { BuildConfiguration.versionDisplay }

    var body: some View {
        VStack(spacing: 0) {
            heroSection

            VStack(spacing: 12) {
                actionsCard
            }
            .padding(.horizontal, 28)

            footerSection
        }
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
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

    // MARK: - Actions

    private var actionsCard: some View {
        sectionCard {
            Button {
                ConsoleNavigation.showSettings()
                ConsoleWindowManager.bringToFront("main")
                onClose()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "fish.fill")
                        .font(.callout)
                    Text("Settings")
                        .font(.callout)
                }
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        VStack(spacing: 6) {
            Text("By DeadRatGames Inc.")

            Text(verbatim: "\u{00A9} \(Calendar.current.component(.year, from: Date())) Console. All rights reserved.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, sectionSpacing)
        .padding(.bottom, 24)
    }

    // MARK: - Shared Components

    private func sectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func actionRow(icon: String, title: String, tint: some ShapeStyle, showArrow: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.callout)
                .frame(width: 16)
            Text(title)
                .font(.callout)
            Spacer()
            if showArrow {
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

#Preview {
    AboutView(onClose: {})
}
