import SwiftUI

/// Reusable card surface for a Home dashboard panel: a consistent header
/// (title plus optional service label) above a replaceable body slot.
struct HomePanelContainer<Content: View>: View {
    let title: String
    var subtitle: String?
    var showsHeader: Bool = true
    var accessibilityIdentifier: String = ""
    @ViewBuilder var content: () -> Content

    init(
        title: String,
        subtitle: String? = nil,
        showsHeader: Bool = true,
        accessibilityIdentifier: String = "",
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.showsHeader = showsHeader
        self.accessibilityIdentifier = accessibilityIdentifier
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                header
                Divider()
            }

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(panelAccessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.headline)
                .lineLimit(1)

            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
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
