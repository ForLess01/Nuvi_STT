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
        isHistoryEnabled: { SettingsStore.shared.saveHistory }
    )

    @Published public private(set) var entries: [HistoryEntry] = []

    private let maxEntries = 500
    let persistenceURL: URL?
    private let isHistoryEnabled: () -> Bool
    private let fileManager: HistoryFileManager
    private let persistenceQueue = DispatchQueue(label: "nuvi.history.persistence", qos: .utility)

    /// A nil URL is deliberately memory-only. Production uses `shared`, while
    /// tests and previews can construct an isolated store without ever touching
    /// the user's Application Support directory.
    public init(
        persistenceURL: URL? = nil,
        isHistoryEnabled: @escaping () -> Bool = { SettingsStore.shared.saveHistory },
        fileManager: FileManager = .default
    ) {
        self.persistenceURL = persistenceURL
        self.isHistoryEnabled = isHistoryEnabled
        self.fileManager = HistoryFileManager(fileManager)
        guard isHistoryEnabled() else {
            purgePersistedHistory()
            return
        }
        if let directory = persistenceURL?.deletingLastPathComponent() {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        load()
    }

    private static func productionPersistenceURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Nuvi", isDirectory: true)
        return dir.appendingPathComponent("history.json")
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
        entries.removeAll()
        guard let persistenceURL else { return }
        let fileManager = fileManager
        persistenceQueue.sync {
            try? fileManager.value.removeItem(at: persistenceURL)
        }
    }

    private func load() {
        guard let persistenceURL,
              let data = fileManager.value.contents(atPath: persistenceURL.path),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        entries = Array(decoded.prefix(maxEntries))
    }

    private func save() {
        guard let persistenceURL else { return }
        guard isHistoryEnabled() else {
            purgePersistedHistory()
            return
        }
        let snapshot = entries
        let fileManager = fileManager
        persistenceQueue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? fileManager.value.createDirectory(
                    at: persistenceURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? data.write(to: persistenceURL, options: .atomic)
                // Owner-only permissions: the file holds dictated speech.
                try? fileManager.value.setAttributes([.posixPermissions: 0o600],
                                                      ofItemAtPath: persistenceURL.path)
            }
        }
    }

    private func purgePersistedHistory() {
        guard let persistenceURL else { return }
        let fileManager = fileManager
        persistenceQueue.sync {
            try? fileManager.value.removeItem(at: persistenceURL)
        }
    }

    /// Test seam for deterministic persistence assertions. Production never
    /// needs to block on the utility queue.
    func flushPersistence() {
        persistenceQueue.sync {}
    }
}
