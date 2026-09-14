import SwiftUI

extension Color {
    /// Neutral button background - #ECECEC
    static let buttonNeutralBackgroundColor = Color(red: 236/255, green: 236/255, blue: 236/255)

    /// The standard green for status indicators and "Done"-style state text
    /// across Console (#007F00). Pure/system green reads washed out on light
    /// surfaces; this darker value keeps the same hue with usable contrast.
    /// The Testing channel's darker #006400 remains deliberately separate.
    static let consoleGreen = Color(hex: "007F00")
}

/// Enables leading-dot syntax (`.consoleGreen`) in ShapeStyle positions such
/// as `foregroundStyle` and `tint`.
extension ShapeStyle where Self == Color {
    static var consoleGreen: Color { Color.consoleGreen }
}
