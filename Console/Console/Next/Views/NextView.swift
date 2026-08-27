import SwiftUI

/// The Next destination: a manual re-check control above the full-width Next
/// card. Entering the view auto-runs the next-task check when no task has been
/// identified yet or the last check is older than the freshness window.
struct NextView: View {
    @Binding var selection: SidebarSelection

    @Environment(AIProviderManager.self) private var aiProviderManager: AIProviderManager?
    @Environment(SessionStore.self) private var sessionStore: SessionStore?
    @State private var model = NextButtonModel()

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            determineButton

            NextTaskCardView(selection: $selection)
                // Ideal-height sizing: the card's internal Spacers are greedy,
                // so without fixedSize they absorb the whole VStack proposal.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: autoCheckIfNeeded)
        .accessibilityIdentifier("NextView")
    }

    /// Smaller capsule control, right-aligned above the card.
    private var determineButton: some View {
        CapsuleButton(
            "Determine Next Task",
            systemImage: "arrow.clockwise",
            style: .outline,
            isDisabled: isChecking,
            controlSize: .small
        ) {
            runCheck()
        }
        .help("Search for the next task now")
        .accessibilityIdentifier("NextView.DetermineButton")
    }

    private var isChecking: Bool {
        if case .checking = model.status { return true }
        return false
    }

    // MARK: - Actions

    private func autoCheckIfNeeded() {
        model.checkIfNeeded(
            sessionStore: sessionStore ?? SessionStore(),
            jiraController: JiraWebSession.shared.panelController,
            aiProviderManager: aiProviderManager
        )
    }

    private func runCheck() {
        model.check(
            sessionStore: sessionStore ?? SessionStore(),
            jiraController: JiraWebSession.shared.panelController,
            aiProviderManager: aiProviderManager
        )
    }
}

#Preview("Idle") {
    @Previewable @State var selection: SidebarSelection = .next
    return NextView(selection: $selection)
        .environment(AIProviderManager())
        .environment(SessionStore())
        .frame(width: 700, height: 500)
}
