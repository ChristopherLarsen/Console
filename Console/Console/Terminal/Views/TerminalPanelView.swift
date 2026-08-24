import SwiftUI

/// Terminal panel with control bar header and content area.
/// Collapsed state keeps only the title bar pinned; the shell session stays alive via `sessionManager`.
struct TerminalPanelView: View {
    let sessionManager: TerminalSessionManager
    @Binding var isExpanded: Bool

    static let barHeight: CGFloat = 36
    static let collapseAnimation = Animation.easeInOut(duration: 0.28)

    var body: some View {
        VStack(spacing: 0) {
            controlBar
                .frame(height: Self.barHeight)

            if isExpanded {
                terminalContent
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .textBackgroundColor))
        .clipped()
    }

    private var controlBar: some View {
        Button {
            withAnimation(Self.collapseAnimation) {
                isExpanded.toggle()
            }
        } label: {
            HStack {
                Text("Terminal")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Spacer()

                Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Collapse Terminal" : "Expand Terminal")
        .accessibilityIdentifier("ToggleTerminalCollapse")
    }

    private var terminalContent: some View {
        ZStack {
            Color.black

            TerminalViewWrapper(sessionManager: sessionManager)
                .padding(10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    @Previewable @State var isExpanded = true
    TerminalPanelView(sessionManager: TerminalSessionManager(), isExpanded: $isExpanded)
        .frame(width: 600, height: 300)
}
