import Foundation

/// Atomic versioned file store under Application Support (or an injected directory).
/// Never silently replaces corrupt / newer-format bytes with an empty store.
actor TicketWorkflowFileStore: TicketWorkflowPersisting {
    nonisolated static let defaultFileName = "ticket-workflow-store.json"
    nonisolated static let subdirectoryComponents = ["Console", "TicketWorkflow"]

    private let directory: URL
    private let fileName: String
    private let fileManager: FileManager
    nonisolated let fileURL: URL

    init(
        directory: URL? = nil,
        fileName: String = TicketWorkflowFileStore.defaultFileName,
        fileManager: FileManager = .default
    ) {
        let resolvedDirectory: URL
        if let directory {
            resolvedDirectory = directory
        } else {
            let appSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            resolvedDirectory = Self.subdirectoryComponents.reduce(appSupport) { partial, component in
                partial.appendingPathComponent(component, isDirectory: true)
            }
        }
        self.directory = resolvedDirectory
        self.fileName = fileName
        self.fileManager = fileManager
        self.fileURL = resolvedDirectory.appendingPathComponent(fileName)
    }

    /// Raw on-disk bytes if present. Used to verify preservation after failures.
    nonisolated func rawBytes() -> Data? {
        try? Data(contentsOf: fileURL)
    }

    nonisolated func fileExists() -> Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    func load() async throws -> TicketWorkflowStoreDTO {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return TicketWorkflowStoreDTO(
                formatVersion: TicketWorkflowStoreDTO.currentFormatVersion,
                workflows: [],
                templates: []
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw TicketWorkflowPersistenceError.corruptStorage
        }

        if data.isEmpty {
            throw TicketWorkflowPersistenceError.corruptStorage
        }

        let dto: TicketWorkflowStoreDTO
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            dto = try decoder.decode(TicketWorkflowStoreDTO.self, from: data)
        } catch {
            throw TicketWorkflowPersistenceError.corruptStorage
        }

        if dto.formatVersion > TicketWorkflowStoreDTO.currentFormatVersion {
            throw TicketWorkflowPersistenceError.newerFormat(version: dto.formatVersion)
        }

        return dto
    }

    func save(_ dto: TicketWorkflowStoreDTO) async throws {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(dto)
            try data.write(to: fileURL, options: .atomic)
        } catch is TicketWorkflowPersistenceError {
            throw TicketWorkflowPersistenceError.saveFailed
        } catch {
            throw TicketWorkflowPersistenceError.saveFailed
        }
    }

    /// Explicit recovery only — removes the durable file after user confirmation.
    func deleteStoreFile() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }
}
