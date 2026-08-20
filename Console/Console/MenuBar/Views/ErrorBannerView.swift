import SwiftUI

struct ErrorBannerView: View {
    let message: String
    let onDismiss: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.title3)
            
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
            
            Spacer()
            
            CloseButton(action: onDismiss)
                .focusable(true)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.yellow.opacity(0.16))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.yellow.opacity(0.28), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

#Preview {
    VStack {
        ErrorBannerView(
            message: "Unable to connect to the gateway. Please check your connection and try again.",
            onDismiss: {}
        )
        .frame(width: 320)
    }
    .padding()
}
