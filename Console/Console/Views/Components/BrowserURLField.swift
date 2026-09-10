import SwiftUI
import WebKit

/// Editable browser-style address bar for a retained `WebPage`. Shows the
/// page's current URL; editing and submitting navigates the page. Pressing
/// Escape reverts to the live URL. Input normalization matches the
/// configured-list URL rules (scheme optional, http/https only).
struct BrowserURLField: View {
    let page: WebPage
    var accessibilityIdentifier: String = "BrowserURLField"

    @State private var editText = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Enter a URL", text: $editText)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
            .focused($isFocused)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .quaternarySystemFill))
            )
            .onSubmit(submit)
            .onChange(of: isFocused) { _, focused in
                if focused {
                    // Start from the live URL, not stale edit text.
                    editText = page.url?.absoluteString ?? ""
                } else {
                    syncDisplayURL()
                }
            }
            .onChange(of: page.url) { _, _ in
                guard !isFocused else { return }
                syncDisplayURL()
            }
            .onKeyPress(.escape) {
                syncDisplayURL()
                isFocused = false
                return .handled
            }
            .onAppear {
                syncDisplayURL()
            }
            .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func submit() {
        guard let url = ListURLNormalization.url(from: editText) else {
            syncDisplayURL()
            isFocused = false
            return
        }
        page.load(URLRequest(url: url))
        isFocused = false
    }

    private func syncDisplayURL() {
        editText = page.url?.absoluteString ?? ""
    }
}
