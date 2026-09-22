import SwiftUI

/// One open merge request offered for one-click attachment: the number, its
/// Jira story key when known, and the title, rendered as a single line.
struct AttachableMergeRequest: Identifiable, Equatable {
    let iid: String
    let jiraKey: String?
    let title: String
    let url: URL

    var id: URL { url }

    /// `MR-1234, NMA-5678, Title` — the key segment is elided when unknown.
    var label: String {
        var parts = ["MR-\(iid)"]
        if let jiraKey { parts.append(jiraKey) }
        parts.append(title)
        return parts.joined(separator: ", ")
    }
}

/// "Attach GitLab" sheet: enter an existing merge request's URL or its number,
/// or pick one of the currently open merge requests, to attach it to the
/// session.
struct ConnectMergeRequestSheet: View {
    @Binding var urlText: String
    let errorText: String?
    let mergeRequests: [AttachableMergeRequest]
    let onPick: (AttachableMergeRequest) -> Void
    let onConnect: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Attach a GitLab Merge Request")
                .font(.headline)

            Text("Enter the merge request URL, or just its number, to attach it to this session.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("https://gitlab.com/group/project/-/merge_requests/42 or 42", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("Sessions.AttachGitLabField")

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("Sessions.AttachGitLabError")
            }

            if !mergeRequests.isEmpty {
                Divider()
                Text("Open merge requests")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(Array(mergeRequests.enumerated()), id: \.element.id) { index, item in
                            Button {
                                onPick(item)
                            } label: {
                                Text(item.label)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color(nsColor: .controlBackgroundColor))
                                    )
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(item.label)
                            .accessibilityLabel(item.label)
                            .accessibilityIdentifier("Sessions.AttachGitLab.Candidate.\(index)")
                        }
                    }
                }
                .frame(maxHeight: 180)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Attach", action: onConnect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("Sessions.AttachGitLabConfirm")
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
