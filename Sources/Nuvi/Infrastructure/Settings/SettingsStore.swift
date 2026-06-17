import Foundation

/// Which transcription engine the app uses. `auto` is the true hybrid: try the
/// native SpeechAnalyzer, fall back to WhisperKit when it can't serve a locale.
public enum EnginePreference: String, CaseIterable, Sendable {
    case auto
    case speechAnalyzer
    case whisperKit

    public var label: String {
        switch self {
        case .auto: return "Auto (SpeechAnalyzer → WhisperKit)"
        case .speechAnalyzer: return "SpeechAnalyzer (native)"
        case .whisperKit: return "WhisperKit"
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

    public func soundPreset(for event: SoundEvent) -> SoundPreset {
        SoundPreset(rawValue: defaults.string(forKey: Keys.soundPreset(event)) ?? "") ?? event.defaultPreset
    }

    public func setSoundPreset(_ preset: SoundPreset, for event: SoundEvent) {
        defaults.set(preset.rawValue, forKey: Keys.soundPreset(event))
    }

    private enum Keys {
        static let locale = "nuvi.locale"
        static let restoreClipboard = "nuvi.restoreClipboard"
        static let engine = "nuvi.engine"
        static let soundEffects = "nuvi.soundEffects"
        static let inputDeviceUID = "nuvi.inputDeviceUID"

        static func soundPreset(_ event: SoundEvent) -> String {
            "nuvi.sound.\(event.rawValue)"
        }
    }
}
