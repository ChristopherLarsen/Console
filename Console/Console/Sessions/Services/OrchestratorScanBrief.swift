import Foundation

/// Builds the compact state brief injected into an orchestrator run prompt.
enum OrchestratorScanBrief {
    static let maxCharacters = 6_000

    /// One typed line that starts a run from a brief written to disk.
    static func runPrompt(briefPath: String) -> String {
        "Run the orchestrator-run skill. Read the Console scan brief at \"\(briefPath)\", "
            + "then load your notes with get_plan. Tell me briefly what you are starting, then go."
    }

    /// Assembles a brief from live sessions and an optional Home board snapshot.
    static func build(
        sessions: [ConsoleSession],
        homeSnapshot: HomeBoardSnapshot?,
        plan: OrchestratorPlan? = nil
    ) -> String {
        var lines: [String] = []
        lines.append("Run the orchestrator-run skill using this Console scan brief.")
        lines.append("Use prompt_console_session to direct existing sessions and create_console_session with initial_prompt for new children.")
        lines.append("")
        if let plan, let data = try? plan.json() {
            lines.append("## Your saved notes (get_plan for the current full version)")
            lines.append(String(String(decoding: data, as: UTF8.self).prefix(3_000)))
            lines.append("")
        }
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
            let inProgress = board.inProgressTickets.prefix(5).map { ticket -> String in
                guard let status = ticket.status?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !status.isEmpty else {
                    return ticket.key
                }
                return "\(ticket.key) (\(status))"
            }
            lines.append("- In progress: \(inProgress.isEmpty ? "(none)" : inProgress.joined(separator: ", "))")
            let reviews = board.reviewQueue.prefix(5).compactMap { item -> String? in
                guard let iid = item.iidText else { return nil }
                return "!\(iid)"
            }
            lines.append("- Review queue: \(reviews.isEmpty ? "(none)" : reviews.joined(separator: ", "))")
        }

        lines.append("")
        lines.append("Say briefly what you are starting, then carry it out. Raise a decision card for anything outward-facing.")
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
            "tool_profile=\(session.toolProfile == .standard ? "full" : "readOnlyPrep")",
            "cwd=\(session.workingDirectory.path)",
        ]
        if let summary = session.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            parts.append("summary=\(String(summary.prefix(120)))")
        }
        if let ask = session.attentionMessage {
            parts.append("needs_user=\(String(ask.prefix(160)))")
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
