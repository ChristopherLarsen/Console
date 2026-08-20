import SwiftUI

/// A customizable sidebar row that replaces NavigationLink for full theming control.
struct SidebarRow: View {
    let label: String
    let icon: String
    let isSelected: Bool
    var isDisabled: Bool = false
    var indented: Bool = false
    var assetIcon: String? = nil
    let action: () -> Void

    @Environment(ThemeManager.self) private var themeManager
    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: { if !isDisabled { action() } }) {
            HStack(spacing: 6) {
                if let assetIcon {
                    Image(assetIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                        .frame(width: 20)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .foregroundStyle(iconColor)
                        .frame(width: 20)
                }

                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(textColor)

                Spacer()
            }
            .padding(.leading, indented ? 28 : 8)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(rowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .opacity(isDisabled ? 0.4 : 1)
        .allowsHitTesting(!isDisabled)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(label)
        .accessibilityIdentifier(label)
    }

    // MARK: - Styling

    private var rowBackground: some View {
        Group {
            if isDisabled {
                Color.clear
            } else if isSelected {
                themeManager.sidebarSelectionBackground
            } else if isHovered {
                themeManager.sidebarHoverBackground
            } else {
                Color.clear
            }
        }
    }

    private var iconColor: Color {
        if isDisabled { return .secondary }
        return isSelected ? themeManager.sidebarSelectedIcon : themeManager.sidebarIcon
    }

    private var textColor: Color {
        if isDisabled { return .secondary }
        return isSelected ? themeManager.sidebarSelectedText : themeManager.sidebarText
    }
}

#Preview("Standard Row - Unselected") {
    SidebarRow(label: "Terminal", icon: "terminal", isSelected: false) {}
        .environment(ThemeManager())
        .padding()
        .background(Color.gray.opacity(0.2))
}

#Preview("Standard Row - Selected") {
    SidebarRow(label: "Terminal", icon: "terminal", isSelected: true) {}
        .environment(ThemeManager())
        .padding()
        .background(Color.gray.opacity(0.2))
}
