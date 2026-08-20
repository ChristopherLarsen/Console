import SwiftUI

@Observable
final class ThemeManager {
    var currentTheme: AppSettings.AppTheme {
        didSet {
            UserDefaults.standard.set(currentTheme.rawValue, forKey: "appTheme")
            UserDefaults.standard.synchronize()
        }
    }
    
    init() {
        if let rawValue = UserDefaults.standard.string(forKey: "appTheme"),
           let theme = AppSettings.AppTheme(rawValue: rawValue) {
            self.currentTheme = theme
        } else {
            self.currentTheme = .systemDefault
        }
    }
    
    var colorScheme: ColorScheme? {
        switch currentTheme {
        case .systemDefault: return nil
        case .systemLight: return .light
        case .systemDark: return .dark
        }
    }
    
    var accentColor: Color { Color.accentColor }
    var selectionBackground: Color { Color.accentColor.opacity(0.25) }
    var tintColor: Color { Color.accentColor }
    var focusRingColor: Color { Color.accentColor }
    var toggleOnColor: Color { Color.accentColor }
    var progressTint: Color { Color.accentColor }

    // MARK: - Sidebar Colors
    
    var sidebarSelectionBackground: Color { Color.accentColor.opacity(0.2) }
    var sidebarHoverBackground: Color { Color.accentColor.opacity(0.1) }
    var sidebarText: Color { Color.primary }
    var sidebarSelectedText: Color { Color.primary }
    var sidebarIcon: Color { Color.secondary }
    var sidebarSelectedIcon: Color { Color.accentColor }
}
