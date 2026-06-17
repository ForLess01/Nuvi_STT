import Foundation
import Combine

/// Persisted, user-editable shortcuts. Push-to-talk is optional (off by default).
@MainActor
public final class ShortcutsStore: ObservableObject {
    public static let shared = ShortcutsStore()

    @Published public var toggle: KeyCombo { didSet { save("nuvi.sc.toggle", toggle) } }
    @Published public var cycleMode: KeyCombo { didSet { save("nuvi.sc.cycle", cycleMode) } }
    @Published public var pushToTalk: KeyCombo? { didSet { saveOptional("nuvi.sc.ptt", pushToTalk) } }

    public init() {
        toggle = Self.load("nuvi.sc.toggle") ?? .toggleDefault
        cycleMode = Self.load("nuvi.sc.cycle") ?? .cycleDefault
        pushToTalk = Self.load("nuvi.sc.ptt")
    }

    private func save(_ key: String, _ combo: KeyCombo) {
        if let data = try? JSONEncoder().encode(combo) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func saveOptional(_ key: String, _ combo: KeyCombo?) {
        if let combo, let data = try? JSONEncoder().encode(combo) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static func load(_ key: String) -> KeyCombo? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(KeyCombo.self, from: data)
    }
}
