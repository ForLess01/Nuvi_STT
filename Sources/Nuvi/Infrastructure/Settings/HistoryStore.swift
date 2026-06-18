import Foundation
import Combine

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
    public static let shared = HistoryStore()

    @Published public private(set) var entries: [HistoryEntry] = []

    private let maxEntries = 500
    private let url: URL
    private let persistenceQueue = DispatchQueue(label: "nuvi.history.persistence", qos: .utility)

    public init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Nuvi", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("history.json")
        load()
    }

    public func add(_ text: String) {
        // Respect the privacy setting: when history is off, dictated text is
        // never stored (not in memory, not on disk).
        guard SettingsStore.shared.saveHistory else { return }
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
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        let snapshot = entries
        let url = url
        persistenceQueue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
                // Owner-only permissions: the file holds dictated speech.
                try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                        ofItemAtPath: url.path)
            }
        }
    }
}
