import SwiftUI

/// A section container for sidebar rows with optional header.
struct SidebarSection<Content: View>: View {
    let header: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let header {
                Text(header)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 8)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
            }

            content()
        }
    }
}

/// A thin horizontal separator line with padding gaps on each side.
struct SidebarSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.5))
            .frame(height: 1)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }
}

#Preview("Separator") {
    VStack {
        Text("Above")
        SidebarSeparator()
        Text("Below")
    }
    .padding()
    .background(Color.gray.opacity(0.3))
}

#Preview("Section without Header") {
    SidebarSection(header: nil) {
        Text("Row 1")
        Text("Row 2")
    }
    .padding()
    .background(Color.gray.opacity(0.2))
}
