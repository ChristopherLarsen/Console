import SwiftUI

/// Restrained empty state for a Home panel that has not been populated yet.
/// Identifies the panel number and the purpose it will serve.
struct HomePanelPlaceholder: View {
    let panelNumber: Int
    let purpose: String

    var body: some View {
        VStack(spacing: 6) {
            Text("Panel \(panelNumber)")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Text(purpose)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Placeholder") {
    HomePanelPlaceholder(
        panelNumber: 1,
        purpose: "Your JIRA tickets will appear here."
    )
    .frame(width: 320, height: 200)
    .padding()
}
