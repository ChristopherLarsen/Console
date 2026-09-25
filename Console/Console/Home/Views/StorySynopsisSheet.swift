import SwiftUI

/// Modal TL;DR for one Next up story.
struct StorySynopsisSheet: View {
    let ticket: JiraTicketSummary
    let controller: StorySynopsisController
    let openInJira: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ticket.key)
                    .font(HomeCardMetrics.identityFont)
                    .foregroundStyle(.secondary)
                Text(ticket.summary)
                    .font(.system(size: 15, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Group {
                switch controller.phase(for: ticket) {
                case .loading:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading the story and writing a synopsis…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                    .accessibilityIdentifier("StorySynopsisLoading")
                case .ready(let synopsis):
                    ScrollView {
                        Text(synopsis.text)
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("StorySynopsisText")
                    }
                    .frame(minHeight: 120, maxHeight: 320)
                    Text("Written by Claude from the JIRA story. Check the story for details.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 8) {
                        Text(message)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Try again") { controller.request(ticket) }
                            .accessibilityIdentifier("StorySynopsisRetry")
                    }
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
                }
            }

            HStack {
                ServiceCapsuleButton(.jira) {
                    dismiss()
                    openInJira()
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("StorySynopsisClose")
            }
        }
        .padding(20)
        .frame(width: 440)
        .accessibilityIdentifier("StorySynopsisSheet")
    }
}
