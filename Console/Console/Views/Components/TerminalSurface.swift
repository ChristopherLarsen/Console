import SwiftUI

/// Shared visual surface for embedded terminals so the zsh drawer and the
/// Sessions terminal pane render identically: black backdrop, 10pt edge
/// padding between surface and terminal, rounded clip, and 10pt outer
/// side/bottom margins with a flush top edge.
struct TerminalSurface<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            Color.black
            content
                .padding(Metrics.edgePadding)
        }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerRadius))
        .padding(.horizontal, Metrics.edgePadding)
        .padding(.bottom, Metrics.edgePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private enum Metrics {
    static let cornerRadius: CGFloat = 6
    static let edgePadding: CGFloat = 10
}

#Preview {
    VStack(spacing: 0) {
        Text("Header")
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        Divider()
        TerminalSurface {
            Color(nsColor: .textBackgroundColor)
        }
    }
    .frame(width: 600, height: 300)
}
