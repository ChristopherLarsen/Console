import SwiftUI

/// "Attach JIRA" sheet: enter a Jira story URL to associate it with the session.
struct ConnectJiraIssueSheet: View {
    @Binding var urlText: String
    let errorText: String?
    let onConnect: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Attach a JIRA Story")
                .font(.headline)

            Text("Enter the Jira story URL to associate it with this session.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("https://jira.example.com/browse/ENG-123", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    guard !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    onConnect()
                }
                .background(TextFieldAutofocus())
                .accessibilityIdentifier("Sessions.AttachJiraField")

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("Sessions.AttachJiraError")
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Attach", action: onConnect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("Sessions.AttachJiraConfirm")
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
