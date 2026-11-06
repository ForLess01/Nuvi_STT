import Foundation
import Combine

private final class HistoryFileManager: @unchecked Sendable {
    let value: FileManager

    init(_ value: FileManager) {
        self.value = value
    }
}

/// One transcription, persisted for the History screen.
public struct HistoryEntry: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public let text: String
    public let date: Date

    public init(id: UUID = UUID(), text: String, date: Date = Date()) {
        self.id = id
        self.text = text
        self.date = date
    }
}

/// Persists transcription history to JSON in Application Support. Capped so it
/// never grows unbounded.
@MainActor
public final class HistoryStore: ObservableObject {
    public static let shared = HistoryStore(
        persistenceURL: productionPersistenceURL(),
        legacyPersistenceURL: productionLegacyPersistenceURL(),
        isHistoryEnabled: { SettingsStore.shared.saveHistory }
    )

    @Published public private(set) var entries: [HistoryEntry] = []

    private let maxEntries = 500
    let persistenceURL: URL?
    private let legacyPersistenceURL: URL?
    @Published public private(set) var lastPersistenceError: String?
    private let isHistoryEnabled: () -> Bool
    private let fileManager: HistoryFileManager
    private var persistenceGeneration = 0
    private var stateURL: URL? { persistenceURL?.appendingPathExtension("state") }
    private let persistenceQueue = DispatchQueue(label: "nuvi.history.persistence", qos: .utility)

    /// A nil URL is deliberately memory-only. Production uses `shared`, while
    /// tests and previews can construct an isolated store without ever touching
    /// the user's Application Support directory.
    public init(
        persistenceURL: URL? = nil,
        legacyPersistenceURL: URL? = nil,
        isHistoryEnabled: @escaping () -> Bool = { SettingsStore.shared.saveHistory },
        fileManager: FileManager = .default
    ) {
        self.persistenceURL = persistenceURL
        self.legacyPersistenceURL = legacyPersistenceURL
        self.isHistoryEnabled = isHistoryEnabled
        self.fileManager = HistoryFileManager(fileManager)
        guard isHistoryEnabled() else {
            purgePersistedHistory()
            return
        }
        migrateIfNeeded()
        load()
    }

    private static func productionPersistenceURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appFolderName = Bundle.main.bundleIdentifier ?? "com.nuvi.app"
        let primaryDir = base.appendingPathComponent(appFolderName, isDirectory: true)
        let primaryFile = primaryDir.appendingPathComponent("history.json")

        return primaryFile
    }

    private static func productionLegacyPersistenceURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nuvi/history.json")
    }

    public func add(_ text: String) {
        // Respect the privacy setting: when history is off, dictated text is
        // never stored (not in memory, not on disk).
        guard isHistoryEnabled() else {
            purgePersistedHistory()
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries.insert(HistoryEntry(text: trimmed), at: 0)
        if entries.count > maxEntries { entries.removeLast(entries.count - maxEntries) }
        save()
    }

    public func delete(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    public func clear() {
        purgePersistedHistory()
    }

    /// The sidecar records migration independently of the data file. A cleared
    /// marker also prevents a failed unlink from making old entries visible.
    private func migrateIfNeeded() {
        guard let persistenceURL, let stateURL,
              !fileManager.value.fileExists(atPath: stateURL.path) else { return }
        do {
            try fileManager.value.createDirectory(
                at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fileManager.value.fileExists(atPath: persistenceURL.path),
               let legacyPersistenceURL,
               fileManager.value.fileExists(atPath: legacyPersistenceURL.path) {
                let data = try Data(contentsOf: legacyPersistenceURL)
                _ = try JSONDecoder().decode([HistoryEntry].self, from: data)
                try Self.writePrivate(data, to: persistenceURL, manager: fileManager.value)
            }
            try Self.writePrivate(Data("migrated".utf8), to: stateURL, manager: fileManager.value)
        } catch {
            report(error.localizedDescription)
        }
    }

    private func load() {
        guard let persistenceURL else { return }
        if let stateURL, (try? String(contentsOf: stateURL, encoding: .utf8)) == "cleared" { return }
        guard fileManager.value.fileExists(atPath: persistenceURL.path) else { return }
        do {
            let data = try Data(contentsOf: persistenceURL)
            entries = Array(try JSONDecoder().decode([HistoryEntry].self, from: data).prefix(maxEntries))
        } catch {
            report(error.localizedDescription)
        }
    }

    private nonisolated static func writePrivate(_ data: Data, to url: URL, manager: FileManager) throws {
        try data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func report(_ message: String?) {
        lastPersistenceError = message
        if let message { NSLog("Nuvi: History persistence failed: %@", message) }
    }

    private func save() {
        guard isHistoryEnabled() else { purgePersistedHistory(); return }
        guard let persistenceURL, let stateURL else { return }
        let snapshot = entries
        let fileManager = fileManager
        persistenceGeneration += 1
        let generation = persistenceGeneration
        persistenceQueue.async { [weak self] in
            let message: String?
            do {
                try fileManager.value.createDirectory(
                    at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Self.writePrivate(try JSONEncoder().encode(snapshot), to: persistenceURL, manager: fileManager.value)
                try Self.writePrivate(Data("migrated".utf8), to: stateURL, manager: fileManager.value)
                message = nil
            } catch { message = error.localizedDescription }
            Task { @MainActor [weak self] in
                guard let self, self.persistenceGeneration == generation else { return }
                self.report(message)
            }
        }
    }

    private func purgePersistedHistory() {
        entries.removeAll()
        persistenceGeneration += 1
        guard let persistenceURL, let stateURL else { return }
        let fileManager = fileManager
        let urls = Set([persistenceURL, legacyPersistenceURL].compactMap { $0 })
        let failures: [String] = persistenceQueue.sync {
            var failures: [String] = []
            do {
                try fileManager.value.createDirectory(
                    at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Self.writePrivate(Data("cleared".utf8), to: stateURL, manager: fileManager.value)
            } catch { failures.append(error.localizedDescription) }
            for url in urls where fileManager.value.fileExists(atPath: url.path) {
                do { try fileManager.value.removeItem(at: url) }
                catch { failures.append(error.localizedDescription) }
            }
            return failures
        }
        report(failures.isEmpty ? nil : failures.joined(separator: "; "))
    }

    /// Test seam for deterministic persistence assertions. Production never
    /// needs to block on the utility queue.
    func flushPersistence() {
        persistenceQueue.sync {}
    }
}
