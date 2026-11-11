import Foundation

/// Builds the compact state brief injected into an orchestrator run prompt.
enum OrchestratorScanBrief {
    static let maxCharacters = 6_000

    /// Assembles a brief from live sessions and an optional Home board snapshot.
    static func build(
        sessions: [ConsoleSession],
        homeSnapshot: HomeBoardSnapshot?
    ) -> String {
        var lines: [String] = []
        lines.append("Run the orchestrator-run skill using this Console scan brief.")
        lines.append("Prefer prompt_console_session for directives after approval; use SendMessage only for FYI.")
        lines.append("")
        lines.append("## Sessions")
        let peers = sessions.filter { $0.purpose != .orchestrator }
        if peers.isEmpty {
            lines.append("- (none besides Orchestrator)")
        } else {
            for session in peers {
                lines.append(sessionLine(session))
            }
        }

        if let homeSnapshot {
            let board = HomeBoardBuilder.build(homeSnapshot)
            lines.append("")
            lines.append("## Home board")
            let nextKeys = board.nextStories.prefix(3).map(\.key)
            lines.append("- Next up: \(nextKeys.isEmpty ? "(none)" : nextKeys.joined(separator: ", "))")
            let inProgress = board.inProgressTickets.prefix(5).map { "\($0.key) (\($0.status))" }
            lines.append("- In progress: \(inProgress.isEmpty ? "(none)" : inProgress.joined(separator: ", "))")
            let reviews = board.reviewQueue.prefix(5).compactMap { item -> String? in
                guard let iid = item.iidText else { return nil }
                return "!\(iid)"
            }
            lines.append("- Review queue: \(reviews.isEmpty ? "(none)" : reviews.joined(separator: ", "))")
        }

        lines.append("")
        lines.append("Propose 1–3 ranked next steps and ask for approval before acting.")
        let text = lines.joined(separator: "\n")
        if text.count <= maxCharacters { return text }
        return String(text.prefix(maxCharacters))
    }

    private static func sessionLine(_ session: ConsoleSession) -> String {
        var parts = [
            session.name,
            "id=\(session.id.uuidString)",
            "purpose=\(session.purpose?.rawValue ?? "unknown")",
            "activity=\(session.activity.rawValue)",
            "attention=\(session.attention.rawValue)",
            "bridge=\(session.bridgeStatus.rawValue)",
        ]
        if let summary = session.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            parts.append("summary=\(String(summary.prefix(120)))")
        }
        let artifacts = session.artifacts.prefix(3).map { artifact in
            if let url = artifact.url {
                return "\(artifact.label) (\(url.absoluteString))"
            }
            return artifact.label
        }
        if !artifacts.isEmpty {
            parts.append("artifacts=\(artifacts.joined(separator: "; "))")
        }
        return "- " + parts.joined(separator: " | ")
    }
}
