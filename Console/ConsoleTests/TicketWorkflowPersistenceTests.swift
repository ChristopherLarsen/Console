import XCTest
@testable import Console

@MainActor
final class TicketWorkflowPersistenceTests: XCTestCase {

    private var tempDirectory: URL!
    private var fileStore: TicketWorkflowFileStore!
    private var identity: FakeTicketIdentityKeyProvider!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TicketWorkflowPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        fileStore = TicketWorkflowFileStore(directory: tempDirectory)
        identity = FakeTicketIdentityKeyProvider()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
        fileStore = nil
        identity = nil
    }

    // MARK: - Round trip

    func testRoundTripRestoresStageAndManualProgressWithoutRerunningJobs() async throws {
        let secret = Data(repeating: 0x42, count: 32)
        identity.secret = secret

        let store = makeStore()
        let token = try await store.makeAssociationToken(
            originHost: "jira.example.test",
            issueKey: "SENSITIVE_TICKET_KEY"
        )
        let workflowID = UUID()
        let template = TicketWorkflowDefaultTemplate.make()
        var steps = template.steps.map { TicketChecklistStepState(from: $0) }
        steps[0].outcome = .acknowledged
        steps[0].satisfiedInCycle = 1
        if let buildIndex = steps.firstIndex(where: { $0.role == .buildPassed }) {
            steps[buildIndex].outcome = .running
        }
        if let testIndex = steps.firstIndex(where: { $0.role == .testsPassed }) {
            steps[testIndex].outcome = .succeeded
            steps[testIndex].satisfiedInCycle = 1
        }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let result = store.dispatch(
            .trackingStarted(TrackingStarted(
                eventID: UUID(),
                workflowID: workflowID,
                association: token,
                templateID: template.id,
                templateVersion: template.version,
                steps: steps,
                workspaceID: UUID(),
                at: now
            )),
            now: now
        )
        XCTAssertNil(result.error)

        // Persist a non-default stage/cycle via DTO rewrite (simulates prior session progress).
        await store.saveProgress()
        var dto = try await fileStore.load()
        dto.workflows[0].currentStage = .verify
        dto.workflows[0].workCycle = 2
        try await fileStore.save(dto)

        let reloaded = makeStore()
        await reloaded.loadProgress()
        XCTAssertEqual(reloaded.persistenceState, .ready)
        let record = try XCTUnwrap(reloaded.workflows[workflowID])
        XCTAssertEqual(record.currentStage, .verify)
        XCTAssertEqual(record.workCycle, 2)
        XCTAssertEqual(record.steps[0].outcome, .acknowledged)
        XCTAssertEqual(
            record.steps.first(where: { $0.role == .buildPassed })?.outcome,
            .running
        )
        XCTAssertEqual(
            record.steps.first(where: { $0.role == .testsPassed })?.outcome,
            .succeeded
        )
        // load does not auto-apply interrupt/revalidation — no job rerun
        XCTAssertFalse(record.steps.contains { $0.outcome == .interrupted })
        XCTAssertFalse(record.steps.contains { $0.outcome == .previouslyPassedNeedsRevalidation })
    }

    // MARK: - Privacy

    func testEncodedStoreBytesOmitSensitiveTicketSentinels() async throws {
        identity.secret = Data(repeating: 0x11, count: 32)
        let store = makeStore()
        let token = try await store.makeAssociationToken(
            originHost: "corp.example.test",
            issueKey: "SENSITIVE_TICKET_KEY"
        )

        let template = TicketWorkflowDefaultTemplate.make()
        let steps = template.steps.map { TicketChecklistStepState(from: $0) }
        let workflowID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        _ = store.dispatch(
            .trackingStarted(TrackingStarted(
                eventID: UUID(),
                workflowID: workflowID,
                association: token,
                templateID: template.id,
                templateVersion: template.version,
                steps: steps,
                workspaceID: nil,
                at: now
            )),
            now: now
        )
        // Memory-only runtime context may carry labels; must not hit disk.
        _ = store.dispatch(
            .attachRuntimeContext(AttachRuntimeContext(
                eventID: UUID(),
                workflowID: workflowID,
                displayKey: "SENSITIVE_TICKET_KEY",
                displayTitle: "SENSITIVE_TITLE",
                observedStatus: "SENSITIVE_STATUS",
                issueURL: URL(string: "https://corp.example.test/browse/SENSITIVE_TICKET_KEY"),
                navigationGeneration: 1,
                at: now
            )),
            now: now
        )
        await store.saveProgress()

        let bytes = try XCTUnwrap(fileStore.rawBytes())
        let json = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(json.contains("SENSITIVE_TICKET_KEY"))
        XCTAssertFalse(json.contains("SENSITIVE_TITLE"))
        XCTAssertFalse(json.contains("SENSITIVE_STATUS"))
        XCTAssertTrue(json.contains("associationDigest"))
        XCTAssertEqual(store.runtimeContext[workflowID]?.displayTitle, "SENSITIVE_TITLE")
        XCTAssertEqual(store.runtimeContext[workflowID]?.displayKey, "SENSITIVE_TICKET_KEY")
    }

    // MARK: - Failure modes

    func testKeychainUnavailableYieldsLockedRetryableAndPreservesFile() async throws {
        identity.secret = Data(repeating: 0x22, count: 32)
        let store = makeStore()
        try await seedOneWorkflow(on: store)
        await store.saveProgress()
        let preserved = try XCTUnwrap(fileStore.rawBytes())

        identity.unavailable = true
        let reloaded = makeStore()
        await reloaded.loadProgress()
        XCTAssertEqual(reloaded.persistenceState, .lockedRetryable)
        XCTAssertTrue(reloaded.workflows.isEmpty)
        XCTAssertEqual(fileStore.rawBytes(), preserved)
    }

    func testMissingIdentityKeyWithExistingRecordsNeedsRecoveryAndPreservesBytes() async throws {
        identity.secret = Data(repeating: 0x33, count: 32)
        let store = makeStore()
        try await seedOneWorkflow(on: store)
        await store.saveProgress()
        let preserved = try XCTUnwrap(fileStore.rawBytes())

        identity.secret = nil
        identity.allowCreate = false
        let reloaded = makeStore()
        await reloaded.loadProgress()
        XCTAssertEqual(reloaded.persistenceState, .missingKeyNeedsRecovery)
        XCTAssertTrue(reloaded.workflows.isEmpty)
        XCTAssertEqual(fileStore.rawBytes(), preserved)
    }

    func testCorruptStoragePreservedNeverSilentEmptyOverwrite() async throws {
        let corrupt = Data("{\"not-valid-ticket-workflow\":true}".utf8)
        try corrupt.write(to: fileStore.fileURL, options: .atomic)
        identity.secret = Data(repeating: 0x44, count: 32)

        let store = makeStore()
        await store.loadProgress()
        XCTAssertEqual(store.persistenceState, .corruptPreserved)
        XCTAssertTrue(store.workflows.isEmpty)
        XCTAssertEqual(fileStore.rawBytes(), corrupt)

        await store.saveProgress()
        XCTAssertEqual(fileStore.rawBytes(), corrupt)
    }

    func testNewerFormatPreservedNeverSilentEmptyOverwrite() async throws {
        let newer = TicketWorkflowStoreDTO(
            formatVersion: TicketWorkflowStoreDTO.currentFormatVersion + 5,
            workflows: [],
            templates: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(newer)
        try data.write(to: fileStore.fileURL, options: .atomic)
        identity.secret = Data(repeating: 0x55, count: 32)

        let store = makeStore()
        await store.loadProgress()
        XCTAssertEqual(
            store.persistenceState,
            .newerFormatPreserved(version: TicketWorkflowStoreDTO.currentFormatVersion + 5)
        )
        XCTAssertEqual(fileStore.rawBytes(), data)

        await store.saveProgress()
        XCTAssertEqual(fileStore.rawBytes(), data)
    }

    func testSaveFailedSurfacesStateWithoutClearingMemory() async throws {
        identity.secret = Data(repeating: 0x66, count: 32)
        let failing = FakeTicketWorkflowPersister(loadDTO: .empty, saveError: .saveFailed)
        let store = TicketWorkflowStore(
            identityKeyManager: identity,
            persister: failing
        )
        try await seedOneWorkflow(on: store)
        XCTAssertEqual(store.workflows.count, 1)

        await store.saveProgress()
        XCTAssertEqual(store.persistenceState, .saveFailed)
        XCTAssertEqual(store.workflows.count, 1)
    }

    // MARK: - Restart hooks

    func testRestartHooksMarkInterruptedAndRevalidationWithoutAutoJobs() async throws {
        identity.secret = Data(repeating: 0x77, count: 32)
        let store = makeStore()
        let token = TicketAssociationToken(digest: Data([0xAB, 0xCD]))
        let template = TicketWorkflowDefaultTemplate.make()
        var steps = template.steps.map { TicketChecklistStepState(from: $0) }

        guard let buildIndex = steps.firstIndex(where: { $0.role == .buildPassed }),
              let testIndex = steps.firstIndex(where: { $0.role == .testsPassed })
        else {
            return XCTFail("missing automated steps")
        }
        steps[buildIndex].outcome = .running
        steps[testIndex].outcome = .succeeded
        let runningID = steps[buildIndex].id
        let succeededID = steps[testIndex].id

        let workflowID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_200)
        _ = store.dispatch(
            .trackingStarted(TrackingStarted(
                eventID: UUID(),
                workflowID: workflowID,
                association: token,
                templateID: template.id,
                templateVersion: template.version,
                steps: steps,
                workspaceID: nil,
                at: now
            )),
            now: now
        )

        let interrupt = store.stepsNeedingInterruptAfterRestart()
        XCTAssertEqual(interrupt.count, 1)
        XCTAssertEqual(interrupt[0].stepIDs, [runningID])

        let revalidate = store.stepsNeedingRevalidationAfterRestart()
        XCTAssertEqual(revalidate.count, 1)
        XCTAssertEqual(revalidate[0].stepIDs, [succeededID])

        store.applyCoordinatorRestartHooks(now: now.addingTimeInterval(10))
        let record = try XCTUnwrap(store.workflows[workflowID])
        XCTAssertEqual(
            record.steps.first(where: { $0.id == runningID })?.outcome,
            .interrupted
        )
        XCTAssertEqual(
            record.steps.first(where: { $0.id == succeededID })?.outcome,
            .previouslyPassedNeedsRevalidation
        )
        XCTAssertEqual(record.lifecycle, .needsReconciliation)
    }

    func testDTOMappingRoundTripPreservesAllowlistedFieldsOnly() throws {
        let digest = Data([0x01, 0x02, 0x03, 0x04])
        let stepTemplate = TicketChecklistStepTemplate(
            id: UUID(),
            stage: .understand,
            role: .scopeUnderstood,
            title: "Scope understood",
            isRequired: true,
            completionSource: .developerAcknowledgement,
            isProtected: true
        )
        var step = TicketChecklistStepState(from: stepTemplate, outcome: .acknowledged)
        step.satisfiedInCycle = 1
        step.updatedAt = Date(timeIntervalSince1970: 100)

        let record = TicketWorkflowRecord(
            id: UUID(),
            association: TicketAssociationToken(digest: digest),
            templateID: UUID(),
            templateVersion: 3,
            lifecycle: .active,
            currentStage: .prepare,
            workCycle: 2,
            steps: [step],
            blockers: [
                TicketWorkflowBlocker(
                    id: UUID(),
                    code: .waitingForReviewer,
                    createdAt: Date(timeIntervalSince1970: 50),
                    clearedAt: nil
                )
            ],
            associatedSessionIDs: [
                TicketAssociatedSession(
                    id: UUID(),
                    sessionID: UUID(),
                    associatedAt: Date(timeIntervalSince1970: 60)
                )
            ],
            workspaceID: UUID(),
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 100),
            closedAt: nil,
            transitionHistory: [
                TicketWorkflowTransition(
                    id: UUID(),
                    at: Date(timeIntervalSince1970: 20),
                    code: .trackingStarted,
                    stage: .understand,
                    stepID: nil,
                    workCycle: 1
                )
            ]
        )

        let dto = TicketWorkflowDTOMapping.recordDTO(from: record)
        XCTAssertEqual(dto.associationDigest, digest)
        XCTAssertEqual(dto.associatedSessionIDs, record.associatedSessionIDs.map(\.sessionID))
        XCTAssertEqual(dto.blockers.first?.code, .waitingForReviewer)

        let restored = TicketWorkflowDTOMapping.record(from: dto)
        XCTAssertEqual(restored.association.digest, digest)
        XCTAssertEqual(restored.currentStage, .prepare)
        XCTAssertEqual(restored.workCycle, 2)
        XCTAssertEqual(restored.steps.first?.outcome, .acknowledged)
        XCTAssertEqual(restored.associatedSessionIDs.map(\.sessionID), dto.associatedSessionIDs)

        let encoded = try JSONEncoder().encode(dto)
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(json.contains("SENSITIVE_TICKET_KEY"))
        XCTAssertFalse(json.contains("SENSITIVE_TITLE"))
        XCTAssertFalse(json.contains("SENSITIVE_STATUS"))
    }

    func testRecoveryResetClearsStoreAndMintsNewKey() async throws {
        identity.secret = Data(repeating: 0x88, count: 32)
        let store = makeStore()
        try await seedOneWorkflow(on: store)
        await store.saveProgress()
        XCTAssertTrue(fileStore.fileExists())

        try await store.resetDurableProgressForRecovery()
        XCTAssertEqual(store.persistenceState, .ready)
        XCTAssertTrue(store.workflows.isEmpty)
        XCTAssertNotNil(identity.secret)
        XCTAssertNotEqual(identity.secret, Data(repeating: 0x88, count: 32))
    }

    // MARK: - Helpers

    private func makeStore() -> TicketWorkflowStore {
        TicketWorkflowStore(
            identityKeyManager: identity,
            persister: fileStore,
            fileStore: fileStore
        )
    }

    private func seedOneWorkflow(on store: TicketWorkflowStore) async throws {
        let token = try await store.makeAssociationToken(
            originHost: "jira.example.test",
            issueKey: "SENSITIVE_TICKET_KEY"
        )
        let template = TicketWorkflowDefaultTemplate.make()
        let steps = template.steps.map { TicketChecklistStepState(from: $0) }
        let now = Date(timeIntervalSince1970: 1_700_000_050)
        _ = store.dispatch(
            .trackingStarted(TrackingStarted(
                eventID: UUID(),
                workflowID: UUID(),
                association: token,
                templateID: template.id,
                templateVersion: template.version,
                steps: steps,
                workspaceID: nil,
                at: now
            )),
            now: now
        )
    }
}

// MARK: - Fakes

private final class FakeTicketIdentityKeyProvider: TicketIdentityKeyManaging, @unchecked Sendable {
    var secret: Data?
    var unavailable = false
    var allowCreate = true

    func installationSecret() async throws -> Data {
        if unavailable {
            throw TicketWorkflowPersistenceError.keychainUnavailable
        }
        if let secret {
            return secret
        }
        guard allowCreate else {
            throw TicketWorkflowPersistenceError.missingIdentityKey
        }
        let minted = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        secret = minted
        return minted
    }

    func existingInstallationSecret() async throws -> Data? {
        if unavailable {
            throw TicketWorkflowPersistenceError.keychainUnavailable
        }
        return secret
    }

    func replaceInstallationSecret() async throws -> Data {
        if unavailable {
            throw TicketWorkflowPersistenceError.keychainUnavailable
        }
        let minted = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        secret = minted
        return minted
    }

    func deleteInstallationSecret() async throws {
        if unavailable {
            throw TicketWorkflowPersistenceError.keychainUnavailable
        }
        secret = nil
    }
}

private actor FakeTicketWorkflowPersister: TicketWorkflowPersisting {
    enum LoadDTO {
        case empty
        case value(TicketWorkflowStoreDTO)
        case error(TicketWorkflowPersistenceError)
    }

    private let loadDTO: LoadDTO
    private let saveError: TicketWorkflowPersistenceError?

    init(loadDTO: LoadDTO, saveError: TicketWorkflowPersistenceError? = nil) {
        self.loadDTO = loadDTO
        self.saveError = saveError
    }

    func load() async throws -> TicketWorkflowStoreDTO {
        switch loadDTO {
        case .empty:
            return TicketWorkflowStoreDTO(
                formatVersion: TicketWorkflowStoreDTO.currentFormatVersion,
                workflows: [],
                templates: []
            )
        case .value(let dto):
            return dto
        case .error(let error):
            throw error
        }
    }

    func save(_ dto: TicketWorkflowStoreDTO) async throws {
        if let saveError {
            throw saveError
        }
        _ = dto
    }
}
