import SwiftUI

struct CapsuleButton: View {
    enum Style {
        case primary
        case neutral
        case outline
        case dark
    }

    let title: String
    let systemImage: String?
    let style: Style
    let isDisabled: Bool
    let action: () -> Void

    init(
        _ title: String,
        systemImage: String? = nil,
        style: Style = .primary,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.style = style
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        if style == .outline {
            outlineButton
        } else {
            filledButton
        }
    }

    private var filledButton: some View {
        Button(action: action) {
            buttonLabel
        }
        .buttonStyle(.borderedProminent)
        .tint(backgroundColor)
        .controlSize(.large)
        .disabled(isDisabled)
    }

    private var outlineButton: some View {
        Button(action: action) {
            buttonLabel
                .foregroundStyle(.primary)
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.primary, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .controlSize(.large)
        .disabled(isDisabled)
    }

    private var buttonLabel: some View {
        Group {
            if let systemImage {
                Label(title, systemImage: systemImage)
                    .fontWeight(.semibold)
            } else {
                Text(title)
                    .fontWeight(.semibold)
            }
        }
    }

    private var backgroundColor: Color {
        switch style {
        case .primary:
            return Color.accentColor
        case .neutral:
            return Color.buttonNeutralBackgroundColor
        case .outline:
            return .clear
        case .dark:
            return Color.accentColor
        }
    }
}
