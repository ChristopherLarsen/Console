import SwiftUI
import AppKit

struct ErrorPopoverView: View {
    let errorText: String
    let onDismiss: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Error")
                    .font(.headline)
                Spacer()
                Button("Close") {
                    onDismiss()
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            ScrollView {
                Text(errorText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }

            Divider()

            HStack {
                Spacer()
                Button(copied ? "Copied ✓" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(errorText, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copied = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(copied)
            }
            .padding(16)
        }
    }
}
