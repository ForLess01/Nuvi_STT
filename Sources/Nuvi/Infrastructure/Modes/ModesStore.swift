import Foundation
import Combine

/// How a mode reshapes the final transcript.
public enum TextFormatting: String, Codable, CaseIterable, Sendable {
    case none
    case sentenceCase
    case lowercase
    case uppercase

    public var label: String {
        switch self {
        case .none: return "As-is"
        case .sentenceCase: return "Sentence case"
        case .lowercase: return "lowercase"
        case .uppercase: return "UPPERCASE"
        }
    }
}

/// A dictation context profile. Post-processing only (no LLM): applies optional
/// vocabulary, a formatting transform, and a prefix/suffix. Can auto-activate
/// when a given app is frontmost.
public struct Mode: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var formatting: TextFormatting
    public var prefix: String
    public var suffix: String
    public var useVocabulary: Bool
    public var autoActivateBundleID: String?

    public init(id: UUID = UUID(),
                name: String = "New mode",
                formatting: TextFormatting = .none,
                prefix: String = "",
                suffix: String = "",
                useVocabulary: Bool = true,
                autoActivateBundleID: String? = nil) {
        self.id = id
        self.name = name
        self.formatting = formatting
        self.prefix = prefix
        self.suffix = suffix
        self.useVocabulary = useVocabulary
        self.autoActivateBundleID = autoActivateBundleID
    }

    public static let `default` = Mode(name: "Default")

    /// Run the transcript through this mode's pipeline.
    @MainActor
    public func transform(_ text: String, vocabulary: VocabularyStore) -> String {
        var result = text
        if useVocabulary { result = vocabulary.apply(to: result) }

        switch formatting {
        case .none: break
        case .lowercase: result = result.lowercased()
        case .uppercase: result = result.uppercased()
        case .sentenceCase: result = Self.sentenceCased(result)
        }

        return prefix + result + suffix
    }

    private static func sentenceCased(_ text: String) -> String {
        var output = ""
        var capitalizeNext = true
        for ch in text {
            if capitalizeNext, ch.isLetter {
                output.append(contentsOf: String(ch).uppercased())
                capitalizeNext = false
            } else {
                output.append(ch)
            }
            if ch == "." || ch == "!" || ch == "?" || ch == "\n" {
                capitalizeNext = true
            }
        }
        return output
    }
}

/// Observable, persisted modes plus the active selection.
@MainActor
public final class ModesStore: ObservableObject {
    public static let shared = ModesStore()

    @Published public var modes: [Mode] { didSet { save() } }
    @Published public var activeModeID: UUID { didSet { saveActive() } }

    private let modesKey = "nuvi.modes"
    private let activeKey = "nuvi.activeMode"
    private var pendingModesSave: DispatchWorkItem?

    public init() {
        let defaults = UserDefaults.standard

        let loadedModes: [Mode]
        if let data = defaults.data(forKey: "nuvi.modes"),
           let decoded = try? JSONDecoder().decode([Mode].self, from: data),
           !decoded.isEmpty {
            loadedModes = decoded
        } else {
            loadedModes = [.default]
        }

        let active: UUID
        if let raw = defaults.string(forKey: "nuvi.activeMode"),
           let id = UUID(uuidString: raw),
           loadedModes.contains(where: { $0.id == id }) {
            active = id
        } else {
            active = loadedModes[0].id
        }

        self.modes = loadedModes
        self.activeModeID = active
    }

    public var activeMode: Mode {
        modes.first { $0.id == activeModeID } ?? modes.first ?? .default
    }

    /// Resolve the mode to use: an app-bound mode wins when that app is frontmost,
    /// otherwise the manually-selected active mode.
    public func effectiveMode(frontmostBundleID: String?) -> Mode {
        if let bundleID = frontmostBundleID,
           let bound = modes.first(where: { $0.autoActivateBundleID == bundleID }) {
            return bound
        }
        return activeMode
    }

    public func add() {
        let mode = Mode()
        modes.append(mode)
        activeModeID = mode.id
    }

    public func delete(_ mode: Mode) {
        guard modes.count > 1 else { return } // always keep at least one
        modes.removeAll { $0.id == mode.id }
        if activeModeID == mode.id { activeModeID = modes[0].id }
    }

    /// Cycle to the next mode (used by the change-mode hotkey).
    public func cycle() {
        guard let index = modes.firstIndex(where: { $0.id == activeModeID }) else { return }
        activeModeID = modes[(index + 1) % modes.count].id
    }

    private func save() {
        pendingModesSave?.cancel()
        let modes = modes
        let modesKey = modesKey
        let work = DispatchWorkItem {
            if let data = try? JSONEncoder().encode(modes) {
                UserDefaults.standard.set(data, forKey: modesKey)
            }
        }
        pendingModesSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func saveActive() {
        UserDefaults.standard.set(activeModeID.uuidString, forKey: activeKey)
    }
}
