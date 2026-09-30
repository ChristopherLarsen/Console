import Foundation
import Observation

struct ToDoItem: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var isCompleted = false
}

@Observable
@MainActor
final class ToDoStore {
    private(set) var items: [ToDoItem] = []
    private(set) var errorMessage: String?
    private(set) var isLoaded = false
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Console/to-do.json")
        do {
            do {
                let data = try Data(contentsOf: self.fileURL)
                items = try JSONDecoder().decode([ToDoItem].self, from: data)
            } catch CocoaError.fileReadNoSuchFile {
                items = []
            }
            isLoaded = true
        } catch {
            errorMessage = "Couldn’t load To Do: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func add(_ title: String) -> Bool {
        guard let title = Self.singleLine(title) else { return false }
        return save(items + [ToDoItem(id: UUID(), title: title)])
    }

    @discardableResult
    func update(_ id: UUID, title: String) -> Bool {
        guard let title = Self.singleLine(title),
              let index = items.firstIndex(where: { $0.id == id }) else { return false }
        guard items[index].title != title else { return true }
        var updated = items
        updated[index].title = title
        return save(updated)
    }

    func setCompleted(_ id: UUID, _ completed: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var updated = items
        updated[index].isCompleted = completed
        save(updated)
    }

    func delete(_ id: UUID) {
        save(items.filter { $0.id != id })
    }

    static func singleLine(_ title: String) -> String? {
        let title = title.split(whereSeparator: { $0.isNewline })
            .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    // Publish changes only after the atomic write succeeds. A failed load
    // disables writes so unreadable existing data can never be overwritten.
    @discardableResult
    private func save(_ updated: [ToDoItem]) -> Bool {
        guard isLoaded else { return false }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(updated).write(to: fileURL, options: .atomic)
            items = updated
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Couldn’t save To Do: \(error.localizedDescription)"
            return false
        }
    }
}
