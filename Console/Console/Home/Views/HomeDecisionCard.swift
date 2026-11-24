import SwiftUI

/// One open Orchestrator decision. Each option is a button: choosing one
/// records the answer in the plan and wakes the Orchestrator.
struct HomeDecisionCard: View {
    let decision: OrchestratorPlan.Decision
    let answer: (String) -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: HomeCardMetrics.rowGap) {
            HStack(spacing: 5) {
                HomeCardGlyph(color: AttentionChannel.needsYou.color, needsYou: true)
                Text("Decision \(decision.id)")
                    .font(HomeCardMetrics.identityFont)
                    .foregroundStyle(.secondary)
                Text("Orchestrator is waiting")
                    .font(HomeCardMetrics.stateEmphasisFont)
                    .foregroundStyle(AttentionChannel.needsYou.color)
                Spacer(minLength: 4)
            }
            Text(decision.question)
                .font(HomeCardMetrics.titleFont)
                .foregroundStyle(.primary)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(decision.question)
            HStack(spacing: 6) {
                ForEach(decision.options, id: \.self) { option in
                    CapsuleActionButton(option) { answer(option) }
                        .accessibilityIdentifier("HomeDecisionOption.\(decision.id).\(option)")
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 4)
        }
        .padding(HomeCardMetrics.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering = $0 }
        .homeCardSurface(hovering: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("HomeDecisionCard.\(decision.id)")
    }
}
