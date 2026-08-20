import SwiftUI

extension Color {
    /// Design system color palette
    enum Theme {
        // MARK: - Accent (AccentColor.colorset Display P3)
        static let accentLight = Color(.displayP3, red: 0.712, green: 0.821, blue: 0.938)
        static let accentDark = Color(.displayP3, red: 0.628, green: 0.725, blue: 0.828)

        // MARK: - Text
        static let textPrimaryLight = Color(hex: "1C1C1E")
        static let textPrimaryDark = Color(hex: "FFFFFF")
        static let textSecondaryLight = Color(hex: "6B6B6B")
        static let textSecondaryDark = Color(hex: "A0A0A0")

        // MARK: - Background
        static let backgroundLight = Color(hex: "FFFFFF")
        static let backgroundDark = Color(hex: "000000")
        static let backgroundSecondaryLight = Color(hex: "F5F5F5")
        static let backgroundSecondaryDark = Color(hex: "1C1C1E")

        // MARK: - Message Bubbles
        static let userBubble = Color(.displayP3, red: 0.712, green: 0.821, blue: 0.938)
        static let assistantBubbleLight = Color(hex: "E8E8E8")
        static let assistantBubbleDark = Color(hex: "2C2C2E")

        // MARK: - Status
        static let errorLight = Color(hex: "FF3B30")
        static let errorDark = Color(hex: "FF453A")
        static let successLight = Color(hex: "34C759")
        static let successDark = Color(hex: "30D158")

        // MARK: - Adaptive Helpers
        static func accent(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? accentDark : accentLight
        }

        static func textPrimary(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? textPrimaryDark : textPrimaryLight
        }

        static func textSecondary(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? textSecondaryDark : textSecondaryLight
        }

        static func background(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? backgroundDark : backgroundLight
        }

        static func backgroundSecondary(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? backgroundSecondaryDark : backgroundSecondaryLight
        }

        static func assistantBubble(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? assistantBubbleDark : assistantBubbleLight
        }

        static func error(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? errorDark : errorLight
        }

        static func success(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? successDark : successLight
        }
    }
}

// MARK: - Hex Initializer
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
