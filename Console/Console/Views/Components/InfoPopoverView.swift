import SwiftUI
import AppKit

struct InfoPopoverView: View {
    let title: String
    let infoText: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.accentColor)

                Text(title)
                    .font(.title3.bold())

                Spacer()

                CloseButton(action: onDismiss)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 16)

            Divider()
                .padding(.horizontal, 20)

            // Content
            ScrollView {
                Group {
                    if let attributed = try? AttributedString(
                        markdown: infoText,
                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                    ) {
                        Text(attributed)
                    } else {
                        Text(infoText)
                    }
                }
                .font(.body)
                .lineSpacing(3)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 24)
            }
        }
    }
}
