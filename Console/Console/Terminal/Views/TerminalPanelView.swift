import SwiftUI

/// Terminal drawer content. The drawer header was removed — expansion is
/// controlled by the sidebar's "Main Terminal" item; the shell session stays
/// alive via `sessionManager` even while the view is unmounted.
struct TerminalPanelView: View {
    let sessionManager: TerminalSessionManager

    static let collapseAnimation = Animation.easeInOut(duration: 0.28)

    var body: some View {
        TerminalSurface {
            TerminalViewWrapper(sessionManager: sessionManager)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MainTerminalDrawer")
    }
}

#Preview {
    TerminalPanelView(sessionManager: TerminalSessionManager())
        .frame(width: 600, height: 300)
}
