import SwiftUI

/// Compact native card for one merge request rendered by the active code
/// host's list.
///
/// At most three rows; the title dominates. Unavailable optional fields are
/// omitted entirely — never guessed, never shown as "Unknown". The whole card
/// is one button that opens the captured absolute MR URL in the shared page.
struct MergeRequestCardView: View {
    let item: MergeRequestSummary
    let opensInPanel: () -> Void

    var body: some View {
        Button(action: opensInPanel) {
            cardBody
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Open merge request in \(AppSettings().codeHostProvider.displayName)")
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(eyebrow)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textCase(.uppercase)

                Spacer(minLength: 4)

                statusCues
            }

            Text(item.title)
                .font(.callout)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .help(item.title)

            if let footer = footerText {
                Text(footer)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 7))
    }

    // MARK: - Fields (omitted cleanly when the host did not render them)

    private var eyebrow: String {
        var parts: [String] = []
        if let project = item.projectDisplayName { parts.append(project) }
        if let iid = item.iidText { parts.append("!\(iid)") }
        return parts.isEmpty ? "" : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var statusCues: some View {
        // At most two cues: Draft plus one visible pipeline state.
        HStack(spacing: 4) {
            if item.isDraft {
                cue(text: "Draft", systemImage: "pencil.line", color: .secondary)
            }
            if let pipeline = item.pipelineDisplayState {
                cue(
                    text: pipeline,
                    systemImage: symbolForPipeline(pipeline),
                    color: colorForPipeline(pipeline)
                )
            }
        }
    }

    private func cue(text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2)
            .foregroundStyle(color)
            .lineLimit(1)
    }

    private var footerText: String? {
        var parts: [String] = []
        if let author = item.authorDisplayName { parts.append(author) }
        if let updated = item.updatedText { parts.append("updated \(updated)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        var parts: [String] = [item.title]
        var context: [String] = []
        if let project = item.projectDisplayName { context.append(project) }
        if let iid = item.iidText { context.append("!\(iid)") }
        if !context.isEmpty { parts.append(context.joined(separator: " · ")) }
        if let author = item.authorDisplayName { parts.append(author) }
        if item.isDraft { parts.append("Draft") }
        if let pipeline = item.pipelineDisplayState { parts.append("Pipeline \(pipeline)") }
        if let updated = item.updatedText { parts.append("updated \(updated)") }
        return parts.joined(separator: ", ")
    }

    private func symbolForPipeline(_ state: String) -> String {
        switch state.lowercased() {
        case "failed": return "xmark.circle"
        case "running", "pending": return "arrow.triangle.2.circlepath"
        case "passed", "success": return "checkmark.circle"
        default: return "circle.dotted"
        }
    }

    private func colorForPipeline(_ state: String) -> Color {
        switch state.lowercased() {
        case "failed": return .red
        case "running", "pending": return .orange
        case "passed", "success": return .green
        default: return .secondary
        }
    }
}

#Preview("Card") {
    MergeRequestCardView(
        item: MergeRequestSummary(
            id: URL(string: "https://example.com/group/project/-/merge_requests/123")!,
            iidText: "123",
            title: "Fix account recovery navigation crash",
            projectDisplayName: "Console iOS",
            authorDisplayName: "Alex Chen",
            isDraft: false,
            pipelineDisplayState: "Failed",
            reviewDisplayState: nil,
            updatedText: "2h ago",
            mergeRequestURL: URL(string: "https://example.com/group/project/-/merge_requests/123")!,
            sourceOrder: 0
        ),
        opensInPanel: {}
    )
    .frame(width: 320)
    .padding()
}
