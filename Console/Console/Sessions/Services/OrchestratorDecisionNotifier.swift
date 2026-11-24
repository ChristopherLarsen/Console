import AppKit
import UserNotifications

/// Tells the user the Orchestrator is waiting on them when Console is not in
/// front: the Dock badge counts open decisions and each new one posts a
/// notification. The Home cards are where they are answered.
@MainActor
enum OrchestratorDecisionNotifier {
    static func update(added: [OrchestratorPlan.Decision], openCount: Int) {
        NSApp.dockTile.badgeLabel = openCount == 0 ? nil : String(openCount)
        guard !added.isEmpty else { return }
        let requests = added.map { decision in
            let content = UNMutableNotificationContent()
            content.title = "Orchestrator needs a decision"
            content.body = decision.question
            content.sound = .default
            return UNNotificationRequest(
                identifier: "orchestrator-decision-\(decision.id)", content: content, trigger: nil
            )
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            for request in requests { center.add(request) }
        }
    }
}
