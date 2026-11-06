import XCTest
@testable import Nuvi

@MainActor
final class HistoryMigrationTests: XCTestCase {
    func testMigratedHistoryDoesNotReturnAfterClearOrDisable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NuviTests-HistoryMigration-\(UUID().uuidString)")
        let legacy = root.appendingPathComponent("legacy.json")
        let current = root.appendingPathComponent("current/history.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode([HistoryEntry(text: "legacy")]).write(to: legacy)
        let store = HistoryStore(persistenceURL: current, legacyPersistenceURL: legacy, isHistoryEnabled: { true })
        XCTAssertEqual(store.entries.map(\.text), ["legacy"])
        store.clear()
        let restarted = HistoryStore(persistenceURL: current, legacyPersistenceURL: legacy, isHistoryEnabled: { true })
        XCTAssertTrue(restarted.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))

        try JSONEncoder().encode([HistoryEntry(text: "old copy")]).write(to: legacy)
        _ = HistoryStore(persistenceURL: current, legacyPersistenceURL: legacy, isHistoryEnabled: { false })
        let enabled = HistoryStore(persistenceURL: current, legacyPersistenceURL: legacy, isHistoryEnabled: { true })
        XCTAssertTrue(enabled.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testFailedDeletionIsReportedAndClearedMarkerPreventsReload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NuviTests-HistoryMigration-\(UUID().uuidString)")
        let current = root.appendingPathComponent("history.json")
        let manager = RejectingHistoryFileManager()
        let store = HistoryStore(persistenceURL: current, isHistoryEnabled: { true }, fileManager: manager)
        store.add("must not reappear")
        store.flushPersistence()
        store.clear()
        XCTAssertNotNil(store.lastPersistenceError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path), "Fixture simulates failed unlink")
        let restarted = HistoryStore(persistenceURL: current, isHistoryEnabled: { true })
        XCTAssertTrue(restarted.entries.isEmpty)
        restarted.add("new entry")
        restarted.flushPersistence()
        let afterSave = HistoryStore(persistenceURL: current, isHistoryEnabled: { true })
        XCTAssertEqual(afterSave.entries.map(\.text), ["new entry"])
    }

    func testExistingPrimaryWinsAndCorruptLegacyIsPreservedWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NuviTests-HistoryMigration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let current = root.appendingPathComponent("history.json")
        let legacy = root.appendingPathComponent("legacy.json")
        try Data("broken".utf8).write(to: legacy)
        let invalid = HistoryStore(persistenceURL: current, legacyPersistenceURL: legacy, isHistoryEnabled: { true })
        XCTAssertNotNil(invalid.lastPersistenceError)
        XCTAssertEqual(try Data(contentsOf: legacy), Data("broken".utf8))
        try JSONEncoder().encode([HistoryEntry(text: "primary")]).write(to: current)
        let primary = HistoryStore(persistenceURL: current, legacyPersistenceURL: legacy, isHistoryEnabled: { true })
        XCTAssertEqual(primary.entries.map(\.text), ["primary"])
    }

    func testTurningHistoryOffAlsoPurgesMemory() {
        var enabled = true
        let store = HistoryStore(isHistoryEnabled: { enabled })
        store.add("private")
        enabled = false
        store.add("not stored")
        XCTAssertTrue(store.entries.isEmpty)
    }
}

private final class RejectingHistoryFileManager: FileManager, @unchecked Sendable {
    override func removeItem(at URL: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}
