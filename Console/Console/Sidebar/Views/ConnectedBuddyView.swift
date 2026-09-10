import SwiftUI
import Foundation

/// Sidebar status card with ConsoleBuddy image, last-request provider connection dot, and machine name.
struct ConnectedBuddyView: View {
    @Environment(AIProviderManager.self) private var aiProviderManager: AIProviderManager?
    /// The provider connection indicator only means something when the AI
    /// provider feature is enabled in Settings.
    @AppStorage(AppSettings.aiProviderEnabledKey) private var isAIProviderEnabled = false

    private var displayName: String {
        Host.current().localizedName ?? "This Mac"
    }

    private var showsConnectionDot: Bool {
        isAIProviderEnabled
            && aiProviderManager?.selectedProvider != .none
            && aiProviderManager?.lastRequest != nil
    }

    private var connectionDotColor: Color? {
        guard showsConnectionDot, let manager = aiProviderManager else { return nil }
        switch manager.lastRequest {
        case .succeeded: return .green
        case .failed: return .red
        case .none: return nil
        }
    }

    private var accessibilityStatus: String {
        guard showsConnectionDot, let manager = aiProviderManager else {
            return displayName
        }
        switch manager.lastRequest {
        case .succeeded:
            return "\(displayName), connected"
        case .failed:
            return "\(displayName), not connected"
        case .none:
            return displayName
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(
                    colors: [Color.Theme.accentLight, Color.Theme.accentDark],
                    startPoint: .top,
                    endPoint: .bottom
                ))

            Image("ConsoleBuddy")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                .padding(16)

            VStack {
                HStack {
                    Spacer()
                    if let color = connectionDotColor {
                        Circle()
                            .fill(color)
                            .frame(width: 12, height: 12)
                            .overlay(
                                Circle()
                                    .stroke(Color.white.opacity(0.5), lineWidth: 1)
                            )
                            .padding(10)
                    }
                }
                Spacer()
            }

            VStack {
                Spacer()
                Text(displayName)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel(accessibilityStatus)
    }
}

#Preview {
    ConnectedBuddyView()
        .frame(width: 180)
        .padding()
}
