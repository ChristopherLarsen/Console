import Foundation

/// Stable accessibility identifiers for Ticket Work. UUID-based; never embed
/// issue keys, titles, or URLs.
enum TicketWorkflowAccessibility {
    static let sidebarItem = "TicketWorkSidebarItem"
    static let list = "TicketWorkList"
    static let listFilterActive = "TicketWorkFilterActive"
    static let listFilterClosed = "TicketWorkFilterClosed"
    static let detail = "TicketWorkDetail"
    static let stageProgress = "TicketWorkStageProgress"
    static let nextAction = "TicketWorkNextAction"
    static let advanceButton = "TicketWorkAdvance"
    static let returnToImplementationButton = "TicketWorkReturnToImplementation"
    static let blockButton = "TicketWorkBlock"
    static let resumeButton = "TicketWorkResume"
    static let forgetButton = "TicketWorkForget"
    static let trackWorkButton = "TicketWorkTrack"
    static let closeWorkflowButton = "TicketWorkClose"
    static let openInJiraButton = "TicketWorkOpenInJira"
    static let checkStatusButton = "TicketWorkCheckStatus"
    static let templateEditor = "TicketWorkTemplateEditor"
    static let persistenceBanner = "TicketWorkPersistenceBanner"
    static let persistenceRetry = "TicketWorkPersistenceRetry"
    static let persistenceReset = "TicketWorkPersistenceReset"

    static func workflowRow(_ id: UUID) -> String {
        "TicketWorkRow.\(id.uuidString)"
    }

    static func stepRow(_ id: UUID) -> String {
        "TicketWorkStep.\(id.uuidString)"
    }
}
