import Foundation

/// Memory-only results strip for Ticket Work detail. Package D / lead supply
/// instances; Package G only renders them. Never embed issue keys, titles, or
/// URLs in identifiers.
nonisolated struct TicketWorkResultsPresentation: Equatable, Sendable, Identifiable {
    var id: UUID
    /// Short outcome line (e.g. "Build succeeded", "3 test failures").
    var headline: String
    /// Bounded supporting lines (file paths / messages already scrubbed upstream).
    var detailLines: [String]
    var outcome: TicketWorkResultsOutcome
    var stepID: UUID?

    init(
        id: UUID = UUID(),
        headline: String,
        detailLines: [String] = [],
        outcome: TicketWorkResultsOutcome,
        stepID: UUID? = nil
    ) {
        self.id = id
        self.headline = headline
        self.detailLines = Array(detailLines.prefix(8))
        self.outcome = outcome
        self.stepID = stepID
    }
}

nonisolated enum TicketWorkResultsOutcome: String, Equatable, Sendable {
    case succeeded
    case failed
    case running
    case unknown
}
