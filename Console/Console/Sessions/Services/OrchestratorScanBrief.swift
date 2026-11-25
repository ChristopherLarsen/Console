import Foundation

/// Builds the compact state brief injected into an orchestrator run prompt.
/// The brief carries facts only; the orchestrator-run skill says what to do.
enum OrchestratorScanBrief {
    static let maxCharacters = 8_000

    /// Home board changes between two Orchestrator runs.
    struct Changes: Equatable {
        /// When the previous run's brief was built; nil on the first run
        /// since Console launched, which has nothing to compare against.
        var since: Date?
        var lines: [String]
    }

    /// One typed line that starts a run from a brief written to disk.
    static func runPrompt(briefPath: String) -> String {
        "Run the orchestrator-run skill. Read the Console scan brief at \"\(briefPath)\", "
            + "then load your notes with get_plan. Tell me briefly what you are starting, then go."
    }

    /// Assembles a brief from live sessions and an optional Home board snapshot.
    static func build(
        sessions: [ConsoleSession],
        homeSnapshot: HomeBoardSnapshot?,
        plan: OrchestratorPlan? = nil,
        liveFacts: [URL: MRLiveFacts] = [:],
        changes: Changes? = nil,
        now: Date = Date()
    ) -> String {
        var lines: [String] = []
        lines.append("# Console scan brief")
        lines.append("Built \(ISO8601DateFormatter().string(from: now)). State only; follow the orchestrator-run skill.")
        lines.append("")
        if let plan {
            lines.append("## Saved plan (revision \(plan.revision); get_plan for all of it)")
            let goal = oneLine(plan.goal, limit: 300)
            lines.append("- Goal: \(goal.isEmpty ? "(none set)" : goal)")
            let counts = Dictionary(grouping: plan.steps, by: \.status).mapValues(\.count)
            let steps = counts.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.value) \($0.key.rawValue)" }
            lines.append("- Steps: \(steps.isEmpty ? "(none)" : steps.joined(separator: ", "))")
            lines.append("- Open decisions: \(plan.decisions.filter { $0.answer == nil }.count)")
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
            if let changes {
                if let since = changes.since {
                    lines.append("### Changed since your last run (\(age(since, now: now)))")
                    lines += changes.lines.isEmpty ? ["- nothing"] : changes.lines.map { "- \($0)" }
                } else {
                    lines.append("### Changed since your last run: no baseline, this is the first run since Console launched")
                }
            }

            let jira = sourceNote(board.jiraHealth, status: homeSnapshot.jiraStatus, now: now)
            lines.append("### Next up — Jira \(jira)")
            if board.jiraHealth.retainsContent {
                let next = board.nextStories.prefix(3)
                lines += next.isEmpty ? ["- (none)"] : next.map(ticketLine)
            }
            lines.append("### In progress — Jira \(jira)")
            if board.jiraHealth.retainsContent {
                let active = board.inProgressTickets.prefix(5)
                lines += active.isEmpty ? ["- (none)"] : active.map(ticketLine)
            }

            lines.append("### Review queue — GitLab scan \(sourceNote(board.reviewHealth, status: homeSnapshot.reviewStatus, now: now))")
            lines.append("Lists open, non-draft merge requests by other people that nobody has approved. One leaving the queue means someone approved it or it closed, not that you approved it. The scan reruns about every 15 minutes; the GitLab line under each item is read live.")
            if board.reviewHealth.retainsContent {
                let reviews = board.reviewQueue.prefix(MRLiveFactsStore.maxItems)
                if reviews.isEmpty { lines.append("- (none)") }
                for item in reviews {
                    lines.append(reviewLine(item))
                    lines.append("  - " + (liveFacts[item.mergeRequestURL]?.briefText(now: now)
                        ?? "GitLab: live state not read; verify before relying on it"))
                }
            }
        }

        let text = lines.joined(separator: "\n")
        if text.count <= maxCharacters { return text }
        return String(text.prefix(maxCharacters))
    }

    /// How far to trust a source's section. Anything but "as of" with no
    /// qualifier means an empty section is unknown, not empty.
    private static func sourceNote(_ health: HomeBoardHealth, status: HomeSourceStatus, now: Date) -> String {
        let read = status.lastSuccessfulExtraction.map { age($0, now: now) }
        switch health {
        case .ready:
            return "(as of \(read ?? "an unknown time"))"
        case .updating:
            return "(refreshing now; showing data from \(read ?? "an earlier read"))"
        case .stale(let reason):
            return "(STALE, last read \(read ?? "at an unknown time")\(reason.map { ": \(oneLine($0, limit: 120))" } ?? ""))"
        case .loading:
            return "(LOADING, no data yet: unknown, NOT empty)"
        case .unconfigured:
            return "(not configured: unknown, NOT empty)"
        case .signedOut:
            return "(signed out: unknown, NOT empty)"
        case .unavailable:
            return "(could not be read: unknown, NOT empty)"
        }
    }

    private static func ticketLine(_ ticket: JiraTicketSummary) -> String {
        let facts = [ticket.issueType, ticket.fixVersion.map { "fix \($0)" }, ticket.priority, ticket.status]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let status = ticket.status?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let head = status.isEmpty ? ticket.key : "\(ticket.key) (\(status))"
        let detail = facts.dropLast(status.isEmpty ? 0 : 1).joined(separator: ", ")
        return "- \(head)\(detail.isEmpty ? "" : " [\(detail)]"): \(oneLine(ticket.summary, limit: 100))"
    }

    private static func reviewLine(_ item: MergeRequestSummary) -> String {
        var parts = ["\(item.iidText.map { "!\($0)" } ?? item.mergeRequestURL.lastPathComponent) \"\(oneLine(item.title, limit: 100))\""]
        if let author = item.authorDisplayName { parts.append("by \(author)") }
        if let key = item.jiraIssueKey { parts.append(key) }
        if let category = item.triageCategory?.title ?? item.reviewDisplayState { parts.append(category) }
        var line = "- " + parts.joined(separator: " | ")
        if let reason = item.triageReason { line += ": \(oneLine(reason, limit: 200))" }
        return line
    }

    private static func age(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds) s ago" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        return "\(seconds / 3600) h \(seconds % 3600 / 60) min ago"
    }

    private static func oneLine(_ text: String, limit: Int) -> String {
        String(text.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(limit))
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
