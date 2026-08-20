import SwiftUI

@Observable
final class ToastCenter {
    static let shared = ToastCenter()
    var message: String?

    func show(message: String) {
        self.message = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard self?.message == message else { return }
            self?.message = nil
        }
    }
}

struct ToastOverlay: View {
    @Bindable var center: ToastCenter

    var body: some View {
        if let message = center.message {
            Text(message)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .padding(.top, 8)
        }
    }
}
