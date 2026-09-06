import SwiftUI

/// The Next destination: a manual re-check control above the full-width Next
/// card. Entering the view auto-runs the next-task check when no task has been
/// identified yet or the last check is older than the freshness window.
///
/// The `NextButtonModel` is app-scoped (injected via the environment) so the
/// five-minute cache survives leaving this destination.
struct NextView: View {
    @Binding var selection: SidebarSelection

    @Environment(SessionStore.self) private var sessionStore: SessionStore?
    @Environment(NextButtonModel.self) private var model

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            determineButton

            NextTaskCardView(selection: $selection, model: model, onRefresh: runCheck)
                // Ideal-height sizing: the card's internal Spacers are greedy,
                // so without fixedSize they absorb the whole VStack proposal.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .top)

            #if DEBUG
            Text(verbatim: "\(model.checkStartCount)")
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .accessibilityIdentifier("NextTaskCheckCount")
                .accessibilityValue("\(model.checkStartCount)")
                .accessibilityLabel("Next check count")
                .frame(width: 1, height: 1)
                .accessibilityAddTraits(.updatesFrequently)
            #endif
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: autoCheckIfNeeded)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("NextView")
    }

    /// Smaller capsule control, right-aligned above the card.
    private var determineButton: some View {
        CapsuleButton(
            "Determine Next Task",
            systemImage: "arrow.clockwise",
            style: .outline,
            isDisabled: model.isChecking,
            controlSize: .small
        ) {
            runCheck()
        }
        .help("Search for the next task now")
        .accessibilityLabel("Determine next task")
        .accessibilityIdentifier("NextView.DetermineButton")
    }

    // MARK: - Actions

    private func autoCheckIfNeeded() {
        model.checkIfNeeded(
            sessionStore: sessionStore,
            jiraController: JiraWebSession.shared.panelController
        )
    }

    private func runCheck() {
        model.check(
            sessionStore: sessionStore,
            jiraController: JiraWebSession.shared.panelController
        )
    }
}

#Preview("Idle") {
    @Previewable @State var selection: SidebarSelection = .next
    return NextView(selection: $selection)
        .environment(SessionStore())
        .environment(NextButtonModel())
        .frame(width: 700, height: 500)
}
