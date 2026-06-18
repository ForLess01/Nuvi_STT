import Foundation

/// Which transcription engine the app uses. `auto` is the true hybrid: try the
/// native SpeechAnalyzer, fall back to WhisperKit when it can't serve a locale.
public enum EnginePreference: String, CaseIterable, Sendable {
    case auto
    case speechAnalyzer
    case whisperKit
    case parakeet

    public var label: String {
        switch self {
        case .auto: return "Auto (SpeechAnalyzer → WhisperKit)"
        case .speechAnalyzer: return "SpeechAnalyzer (native)"
        case .whisperKit: return "WhisperKit"
        case .parakeet: return "Parakeet (FluidAudio)"
        }
    }
}

/// Minimal persisted settings the runtime reads.
public final class SettingsStore: @unchecked Sendable {
    public static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    public var localeIdentifier: String {
        get { defaults.string(forKey: Keys.locale) ?? "es-ES" }
        set { defaults.set(newValue, forKey: Keys.locale) }
    }

    public var restoreClipboard: Bool {
        get { defaults.object(forKey: Keys.restoreClipboard) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.restoreClipboard) }
    }

    /// Whether transcriptions are persisted to the on-disk history. Off keeps
    /// dictated text out of `history.json` entirely (privacy).
    public var saveHistory: Bool {
        get { defaults.object(forKey: Keys.saveHistory) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.saveHistory) }
    }

    public var soundEffects: Bool {
        get { defaults.object(forKey: Keys.soundEffects) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.soundEffects) }
    }

    /// Which input device to capture from, by CoreAudio device UID.
    ///   ""        → Automatic: built-in mic if present, else system default. Keeps
    ///               a Bluetooth headset in A2DP so its music is never degraded.
    ///   "default" → follow the system default input.
    ///   "<uid>"   → pin to that specific device.
    public var inputDeviceUID: String {
        get { defaults.string(forKey: Keys.inputDeviceUID) ?? "" }
        set { defaults.set(newValue, forKey: Keys.inputDeviceUID) }
    }

    public var enginePreference: EnginePreference {
        // Default to the native engine: reliable, no downloads. WhisperKit (and
        // the hybrid that can fall back to it) are opt-in from Settings.
        get { EnginePreference(rawValue: defaults.string(forKey: Keys.engine) ?? "") ?? .speechAnalyzer }
        set { defaults.set(newValue.rawValue, forKey: Keys.engine) }
    }

    public var selectedModelID: String {
        get { defaults.string(forKey: Keys.selectedModelID) ?? "openai_whisper-tiny" }
        set { defaults.set(newValue, forKey: Keys.selectedModelID) }
    }

    /// Parakeet model ids that finished downloading at least once. FluidAudio
    /// owns its model cache (no documented path), so we track "downloaded" with
    /// our own persisted flag rather than scanning disk.
    public var downloadedParakeetModels: Set<String> {
        get {
            let array = defaults.stringArray(forKey: Keys.downloadedParakeet) ?? []
            return Set(array)
        }
        set { defaults.set(Array(newValue), forKey: Keys.downloadedParakeet) }
    }

    public func soundPreset(for event: SoundEvent) -> SoundPreset {
        SoundPreset(rawValue: defaults.string(forKey: Keys.soundPreset(event)) ?? "") ?? event.defaultPreset
    }

    public func setSoundPreset(_ preset: SoundPreset, for event: SoundEvent) {
        defaults.set(preset.rawValue, forKey: Keys.soundPreset(event))
    }

    private enum Keys {
        static let locale = "nuvi.locale"
        static let restoreClipboard = "nuvi.restoreClipboard"
        static let saveHistory = "nuvi.saveHistory"
        static let engine = "nuvi.engine"
        static let soundEffects = "nuvi.soundEffects"
        static let inputDeviceUID = "nuvi.inputDeviceUID"
        static let selectedModelID = "nuvi.selectedModelID"
        static let downloadedParakeet = "nuvi.downloadedParakeetModels"

        static func soundPreset(_ event: SoundEvent) -> String {
            "nuvi.sound.\(event.rawValue)"
        }
    }
}
