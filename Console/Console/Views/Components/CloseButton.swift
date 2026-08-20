import SwiftUI

struct CloseButton: View {
    var tint: Color?
    let action: () -> Void

    init(tint: Color? = nil, action: @escaping () -> Void) {
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint ?? Color(.secondaryLabelColor))
                .frame(width: 26, height: 26)
                .background((tint ?? Color(nsColor: .separatorColor)).opacity(0.2))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }
}
