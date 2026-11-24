import SwiftUI

/// One open Orchestrator decision. Each option is a button: choosing one
/// records the answer in the plan and wakes the Orchestrator.
enum HomeOrchestratorCardMetrics {
    /// Every card in the Orchestrator section is exactly this tall, so the
    /// grid reads as one even row. A long plan scrolls inside its card.
    static let height: CGFloat = 190
}

/// One open Orchestrator decision: which session it is about, the current
/// state, the question, and one button per option. Choosing an option records
/// the answer in the plan and wakes the Orchestrator.
struct HomeDecisionCard: View {
    let decision: OrchestratorPlan.Decision
    /// The session's name when the decision names a live session.
    let sessionName: String?
    let openSession: (() -> Void)?
    let answer: (String) -> Void

    @State private var hovering = false

    private var title: String {
        let fallback = decision.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return sessionName ?? (fallback.isEmpty ? "Orchestrator" : fallback)
    }

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
            Button(action: { openSession?() }) {
                Text(title)
                    .font(HomeCardMetrics.titleFont)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(openSession == nil)
            .help(openSession == nil ? title : "Open \(title)")
            .accessibilityIdentifier("HomeDecisionTitle.\(decision.id)")
            if let summary = decision.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(summary)
            }
            Text(decision.question)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(decision.question)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                ForEach(decision.options, id: \.self) { option in
                    CapsuleActionButton(option) { answer(option) }
                        .accessibilityIdentifier("HomeDecisionOption.\(decision.id).\(option)")
                }
                Spacer(minLength: 0)
            }
        }
        .padding(HomeCardMetrics.padding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: HomeOrchestratorCardMetrics.height)
        .onHover { hovering = $0 }
        .homeCardSurface(hovering: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("HomeDecisionCard.\(decision.id)")
    }
}

/// The Orchestrator's proposed plan, shown in full before the user approves
/// it: the goal, then every step with the session that will carry it out.
struct HomePlanCard: View {
    let plan: OrchestratorPlan
    let ownerName: (UUID) -> String?
    let approve: () -> Void
    let discuss: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: HomeCardMetrics.rowGap) {
            HStack(spacing: 5) {
                HomeCardGlyph(color: AttentionChannel.needsYou.color, needsYou: true)
                Text("Plan")
                    .font(HomeCardMetrics.identityFont)
                    .foregroundStyle(.secondary)
                Text("Waiting for your approval")
                    .font(HomeCardMetrics.stateEmphasisFont)
                    .foregroundStyle(AttentionChannel.needsYou.color)
                Spacer(minLength: 4)
            }
            Text(plan.goal.isEmpty ? "No goal stated" : plan.goal)
                .font(HomeCardMetrics.titleFont)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .help(plan.goal)
                .frame(maxWidth: .infinity, alignment: .leading)
            ScrollView {
                VStack(alignment: .leading, spacing: HomeCardMetrics.rowGap) {
                    ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(index + 1).")
                                .font(HomeCardMetrics.identityFont)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(step.ownerSession.flatMap(ownerName) ?? "New session")
                                    .font(HomeCardMetrics.stateFont)
                                    .foregroundStyle(.secondary)
                                Text(step.directive)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                CapsuleActionButton("Approve plan", action: approve)
                    .accessibilityIdentifier("HomePlanApprove")
                CapsuleActionButton("Discuss in Orchestrator", action: discuss)
                    .help("Open the Orchestrator session to change the plan")
                Spacer(minLength: 0)
            }
            .padding(.top, 4)
        }
        .padding(HomeCardMetrics.padding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: HomeOrchestratorCardMetrics.height)
        .onHover { hovering = $0 }
        .homeCardSurface(hovering: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("HomePlanCard")
    }
}
