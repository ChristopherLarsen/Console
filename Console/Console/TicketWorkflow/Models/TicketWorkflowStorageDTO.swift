import Foundation

// MARK: - Durable storage DTO (package B) — allowlisted fields only

/// Versioned on-disk representation. Explicit fields; never encode
/// `JiraTicketSummary`, session summaries, or job diagnostics here.
nonisolated struct TicketWorkflowStoreDTO: Equatable, Sendable, Codable {
    var formatVersion: Int
    var workflows: [TicketWorkflowRecordDTO]
    var templates: [TicketWorkflowTemplateDTO]

    static let currentFormatVersion = 1
}

nonisolated struct TicketWorkflowRecordDTO: Equatable, Sendable, Codable {
    var id: UUID
    var associationDigest: Data
    var templateID: UUID
    var templateVersion: Int
    var lifecycle: TicketWorkflowLifecycle
    var currentStage: TicketWorkflowStage
    var workCycle: Int
    var steps: [TicketChecklistStepStateDTO]
    var blockers: [TicketWorkflowBlockerDTO]
    var associatedSessionIDs: [UUID]
    var workspaceID: UUID?
    var createdAt: Date
    var updatedAt: Date
    var closedAt: Date?
    var transitionHistory: [TicketWorkflowTransitionDTO]
}

nonisolated struct TicketChecklistStepStateDTO: Equatable, Sendable, Codable {
    var id: UUID
    var templateStepID: UUID
    var stage: TicketWorkflowStage
    var role: TicketStepRole
    var title: String
    var isRequired: Bool
    var completionSource: TicketStepCompletionSource
    var isProtected: Bool
    var outcome: TicketStepOutcome
    var updatedAt: Date?
    var satisfiedInCycle: Int?
}

nonisolated struct TicketWorkflowBlockerDTO: Equatable, Sendable, Codable {
    var id: UUID
    var code: TicketBlockerCode
    var createdAt: Date
    var clearedAt: Date?
}

nonisolated struct TicketWorkflowTransitionDTO: Equatable, Sendable, Codable {
    var id: UUID
    var at: Date
    var code: TicketWorkflowTransitionCode
    var stage: TicketWorkflowStage?
    var stepID: UUID?
    var workCycle: Int
}

nonisolated struct TicketWorkflowTemplateDTO: Equatable, Sendable, Codable {
    var id: UUID
    var version: Int
    var displayName: String
    var terminalJiraStatus: String
    var steps: [TicketChecklistStepTemplateDTO]
}

nonisolated struct TicketChecklistStepTemplateDTO: Equatable, Sendable, Codable {
    var id: UUID
    var stage: TicketWorkflowStage
    var role: TicketStepRole
    var title: String
    var isRequired: Bool
    var completionSource: TicketStepCompletionSource
    var isProtected: Bool
}

// MARK: - Identity (package B)

nonisolated enum TicketAssociationDomain {
    /// Domain separation string for HMAC over origin + issue key.
    static let hmacDomain = "console.ticket-workflow.v1"
}

nonisolated protocol TicketIdentityKeyProviding: Sendable {
    func installationSecret() async throws -> Data
}

/// Package B — existing-secret lookup and explicit recovery (not frozen for UI).
nonisolated protocol TicketIdentityKeyManaging: TicketIdentityKeyProviding {
    func existingInstallationSecret() async throws -> Data?
    func replaceInstallationSecret() async throws -> Data
    func deleteInstallationSecret() async throws
}

nonisolated protocol TicketWorkflowPersisting: Sendable {
    func load() async throws -> TicketWorkflowStoreDTO
    func save(_ dto: TicketWorkflowStoreDTO) async throws
}

nonisolated enum TicketWorkflowPersistenceError: Error, Equatable, Sendable {
    case keychainUnavailable
    case missingIdentityKey
    case corruptStorage
    case newerFormat(version: Int)
    case saveFailed
}

nonisolated enum TicketWorkflowPersistenceState: Equatable, Sendable {
    case ready
    case lockedRetryable
    case missingKeyNeedsRecovery
    case corruptPreserved
    case newerFormatPreserved(version: Int)
    case saveFailed
}
