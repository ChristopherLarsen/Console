import XCTest
@testable import Console

@MainActor
final class ToDoStoreTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL { directory.appendingPathComponent("to-do.json") }

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToDoTests-\(UUID())", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testCRUDAndCompletionPersistAcrossReloads() throws {
        let store = ToDoStore(fileURL: fileURL)
        XCTAssertTrue(store.add("  First\nitem  "))
        XCTAssertTrue(store.add("Second item"))
        let first = try XCTUnwrap(store.items.first)
        XCTAssertEqual(first.title, "First item")
        XCTAssertTrue(store.update(first.id, title: "Edited item"))
        store.setCompleted(first.id, true)

        let reloaded = ToDoStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.items, store.items)
        XCTAssertTrue(reloaded.items[0].isCompleted)
        XCTAssertEqual(reloaded.items[0].title, "Edited item")
        reloaded.delete(first.id)
        XCTAssertEqual(ToDoStore(fileURL: fileURL).items.map(\.title), ["Second item"])
    }

    func testBlankInputDoesNotEraseAnItem() throws {
        let store = ToDoStore(fileURL: fileURL)
        XCTAssertFalse(store.add(" \n "))
        XCTAssertTrue(store.add("Keep me"))
        let item = try XCTUnwrap(store.items.first)
        XCTAssertFalse(store.update(item.id, title: "  "))
        XCTAssertEqual(ToDoStore(fileURL: fileURL).items, [item])
    }

    func testUnreadableDataIsPreserved() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let invalid = Data("invalid json".utf8)
        try invalid.write(to: fileURL)
        let store = ToDoStore(fileURL: fileURL)
        XCTAssertFalse(store.isLoaded)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.add("Would overwrite"))
        store.delete(UUID())
        XCTAssertEqual(try Data(contentsOf: fileURL), invalid)
    }

    func testFailedSaveKeepsPriorItems() throws {
        let store = ToDoStore(fileURL: fileURL)
        XCTAssertTrue(store.add("Keep me"))
        let saved = store.items
        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: true)
        XCTAssertFalse(store.update(saved[0].id, title: "Lost edit"))
        store.setCompleted(saved[0].id, true)
        store.delete(saved[0].id)
        XCTAssertEqual(store.items, saved)
        XCTAssertNotNil(store.errorMessage)
    }
}
