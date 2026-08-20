import SwiftUI

/// Informational popup shown before the system Keychain permission dialog.
/// Prepares the user for the upcoming macOS security prompt.
struct KeychainAccessPopup: View {
    var onConfirm: (() -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                CloseButton {
                    withAnimation(.easeOut(duration: 0.2)) {
                        onDismiss?()
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .padding(.trailing, 16)
            .padding(.top, 12)

            Image("yellow_fish")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 80, height: 80)
                .padding(.bottom, 16)

            Text("Console is Smart Now!")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .padding(.bottom, 10)

            Text("To keep your API key safe, Console will store it in the macOS Keychain. You may see a system security prompt — this is normal and ensures your key is encrypted and protected.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 32)
                .padding(.bottom, 24)

            CapsuleButton("Yes, Keep it Safe", systemImage: "lock.shield") {
                withAnimation(.easeOut(duration: 0.2)) {
                    onConfirm?()
                }
            }
            .padding(.bottom, 24)
        }
        .frame(width: 400)
    }
}
