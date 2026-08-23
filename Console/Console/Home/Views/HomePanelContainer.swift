import SwiftUI

/// Reusable card surface for a Home dashboard panel: rounded chrome and an
/// accessibility identity above a replaceable body slot.
///
/// The container deliberately renders no header. Each of the four panels owns
/// exactly one `HomePanelHeader` (title, quiet service-and-count run,
/// icon-only actions) so no panel ever stacks two headers
/// (Design/HomeCards/DESIGN_PROMPT.md §4.4).
struct HomePanelContainer<Content: View>: View {
    let title: String
    var subtitle: String?
    var accessibilityIdentifier: String = ""
    @ViewBuilder var content: () -> Content

    init(
        title: String,
        subtitle: String? = nil,
        accessibilityIdentifier: String = "",
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accessibilityIdentifier = accessibilityIdentifier
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(panelAccessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var panelAccessibilityLabel: String {
        guard let subtitle else { return title }
        return "\(subtitle) — \(title)"
    }
}

#Preview("Container") {
    HomePanelContainer(title: "My Tickets", subtitle: "JIRA") {
        Text("Content goes here")
            .foregroundStyle(.secondary)
    }
    .frame(width: 320, height: 200)
    .padding()
}
