import SwiftUI

/// A custom sidebar list container that replaces SwiftUI List for full styling control.
struct CustomSidebarList<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }
}

#Preview("Custom Sidebar List") {
    CustomSidebarList {
        SidebarSection(header: nil) {
            Text("Terminal")
            Text("Settings")
        }
    }
    .frame(width: 220, height: 400)
    .background(Color.gray.opacity(0.2))
}
