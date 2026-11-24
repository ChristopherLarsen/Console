import Foundation

/// Turns successive Home board snapshots into short change lines the
/// Orchestrator is woken with. Only lists a source actually read are
/// compared, so a refresh in flight or a failed check never reads as "every
/// item left the board".
struct HomeBoardEvents: Equatable {
    static let maxEvents = 8

    private var tickets: [String: JiraTicketSummary]?
    private var reviews: [URL: MergeRequestSummary]?

    /// Changes since the last list each source successfully read. The first
    /// successful read of a source is the baseline and reports nothing.
    mutating func observe(_ snapshot: HomeBoardSnapshot) -> [String] {
        var events: [String] = []

        if snapshot.jiraStatus.check == .current {
            let current = Dictionary(snapshot.jiraTickets.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            if let previous = tickets {
                for ticket in snapshot.jiraTickets {
                    let status = ticket.status ?? "no status"
                    if let old = previous[ticket.key] {
                        if old.status != ticket.status {
                            events.append("\(ticket.key) moved from \(old.status ?? "no status") to \(status)")
                        }
                    } else {
                        events.append("\(ticket.key) joined the board (\(status)): \(Self.short(ticket.summary))")
                    }
                }
                for key in previous.keys.sorted() where current[key] == nil {
                    events.append("\(key) left the board")
                }
            }
            tickets = current
        }

        if snapshot.reviewStatus.check == .current {
            let current = Dictionary(snapshot.reviewItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            if let previous = reviews {
                for item in snapshot.reviewItems {
                    let name = Self.name(item)
                    guard let old = previous[item.id] else {
                        events.append("review requested on \(name): \(Self.short(item.title))")
                        continue
                    }
                    if old.pipelineDisplayState != item.pipelineDisplayState, let state = item.pipelineDisplayState {
                        events.append("\(name) pipeline is now \(state)")
                    }
                    if old.reviewDisplayState != item.reviewDisplayState, let state = item.reviewDisplayState {
                        events.append("\(name) review is now \(state)")
                    }
                }
                for item in previous.values.sorted(by: { $0.sourceOrder < $1.sourceOrder }) where current[item.id] == nil {
                    events.append("\(Self.name(item)) left the review queue")
                }
            }
            reviews = current
        }

        guard events.count > Self.maxEvents else { return events }
        return Array(events.prefix(Self.maxEvents)) + ["\(events.count - Self.maxEvents) more changes"]
    }

    private static func name(_ item: MergeRequestSummary) -> String {
        item.iidText.map { $0.hasPrefix("!") ? $0 : "!\($0)" } ?? item.mergeRequestURL.lastPathComponent
    }

    private static func short(_ text: String) -> String {
        String(text.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(80))
    }
}
