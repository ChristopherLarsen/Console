import SwiftUI

// System themes use macOS default; Console theme uses AccentColor.

/// Toggle style that uses theme accent color for the on state.
struct ThemedToggleStyle: ToggleStyle {
    @Environment(ThemeManager.self) private var themeManager
    
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            Toggle(configuration)
                .labelsHidden()
                .tint(themeManager.toggleOnColor)
        }
    }
}

/// Custom switch toggle with manual rendering for full control over colors.
struct ThemedSwitchStyle: ToggleStyle {
    @Environment(ThemeManager.self) private var themeManager
    
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            RoundedRectangle(cornerRadius: 16)
                .fill(configuration.isOn ? themeManager.toggleOnColor : Color(nsColor: .separatorColor))
                .frame(width: 50, height: 30)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .shadow(radius: 1, y: 1)
                        .padding(3)
                }
                .animation(.easeInOut(duration: 0.2), value: configuration.isOn)
                .onTapGesture {
                    configuration.isOn.toggle()
                }
        }
    }
}

// MARK: - View Extensions

extension View {
    /// Applies themed toggle style using theme accent color.
    func themedToggleStyle() -> some View {
        self.toggleStyle(ThemedToggleStyle())
    }
    
    /// Applies themed custom switch style for full color control.
    func themedSwitchStyle() -> some View {
        self.toggleStyle(ThemedSwitchStyle())
    }
}

// MARK: - Preview

#Preview("Themed Toggles") {
    struct PreviewContainer: View {
        @State private var isOn1 = true
        @State private var isOn2 = false
        @State private var isOn3 = true
        
        var body: some View {
            let themeManager = ThemeManager()
            
            Form {
                Section("Standard Toggle") {
                    Toggle("Themed Toggle On", isOn: $isOn1)
                        .themedToggleStyle()
                    
                    Toggle("Themed Toggle Off", isOn: $isOn2)
                        .themedToggleStyle()
                }
                
                Section("Custom Switch") {
                    Toggle("Custom Switch", isOn: $isOn3)
                        .themedSwitchStyle()
                }
            }
            .padding()
            .frame(width: 300)
            .environment(themeManager)
        }
    }
    
    return PreviewContainer()
}
