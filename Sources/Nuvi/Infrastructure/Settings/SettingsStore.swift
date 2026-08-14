import Foundation

extension Notification.Name {
    static let nuviTranscriptionConfigurationDidChange = Notification.Name("nuvi.transcriptionConfigurationDidChange")
    static let nuviOutputPreferencesDidChange = Notification.Name("nuvi.outputPreferencesDidChange")
    static let nuviPresentationPreferencesDidChange = Notification.Name("nuvi.presentationPreferencesDidChange")
}

public struct TranscriptionConfiguration: Equatable, Sendable {
    public static let defaultWhisperModelID = "openai_whisper-tiny"
    public static let defaultParakeetModelID = "parakeet-tdt-0.6b-v3"

    public let engine: EnginePreference
    public let modelID: String

    public init(engine: EnginePreference, modelID: String) {
        self.engine = engine
        self.modelID = modelID
    }

    public var identity: String { "\(engine.rawValue):\(modelID)" }

    /// Keeps incompatible model families out of their engine adapters. This is
    /// deliberately enforced below the UI because preferences can survive app
    /// upgrades and can also be edited outside the model library.
    public var normalized: TranscriptionConfiguration {
        let expectedModelID: String
        switch engine {
        case .parakeet:
            expectedModelID = modelID.hasPrefix("parakeet-") ? modelID : Self.defaultParakeetModelID
        case .auto, .speechAnalyzer, .whisperKit:
            expectedModelID = modelID.hasPrefix("openai_whisper-") ? modelID : Self.defaultWhisperModelID
        }
        return TranscriptionConfiguration(engine: engine, modelID: expectedModelID)
    }
}

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

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var localeIdentifier: String {
        get { defaults.string(forKey: Keys.locale) ?? "es-ES" }
        set { defaults.set(newValue, forKey: Keys.locale) }
    }

    /// UI language for the Settings window ("en" | "es"). Empty → follow system
    /// on first launch.
    public var interfaceLanguage: String {
        get { defaults.string(forKey: Keys.interfaceLanguage) ?? "" }
        set { defaults.set(newValue, forKey: Keys.interfaceLanguage) }
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

    /// Keeps the floating transcription pill available by default, while
    /// allowing users who prefer a menu-bar-only workflow to suppress it.
    public var showPill: Bool {
        get { defaults.object(forKey: Keys.showPill) as? Bool ?? true }
        set {
            guard newValue != showPill else { return }
            defaults.set(newValue, forKey: Keys.showPill)
            notifyPresentationPreferencesChanged()
        }
    }

    /// When enabled, the status item expands beside the isologo while Nuvi is
    /// active (for example, "Listening…"). Idle always remains icon-only.
    public var showMenuBarStatus: Bool {
        get { defaults.object(forKey: Keys.showMenuBarStatus) as? Bool ?? true }
        set {
            guard newValue != showMenuBarStatus else { return }
            defaults.set(newValue, forKey: Keys.showMenuBarStatus)
            notifyPresentationPreferencesChanged()
        }
    }

    /// Final language delivered to the focused app. Original is deliberately
    /// the privacy-preserving, zero-latency default.
    public var translationTarget: TranslationTarget {
        get {
            TranslationTarget(rawValue: defaults.string(forKey: Keys.translationTarget) ?? "") ?? .original
        }
        set {
            guard newValue != translationTarget else { return }
            defaults.set(newValue.rawValue, forKey: Keys.translationTarget)
            notifyOutputPreferencesChanged()
        }
    }

    /// Standard delivers one settled result. Live writes provisional partials
    /// into the focused editor and reconciles them as recognition stabilizes.
    public var dictationDeliveryMode: DictationDeliveryMode {
        get {
            DictationDeliveryMode(rawValue: defaults.string(forKey: Keys.dictationDeliveryMode) ?? "")
                ?? .standard
        }
        set {
            guard newValue != dictationDeliveryMode else { return }
            defaults.set(newValue.rawValue, forKey: Keys.dictationDeliveryMode)
            notifyOutputPreferencesChanged()
        }
    }

    public var hasAcknowledgedLiveMode: Bool {
        get { defaults.bool(forKey: Keys.hasAcknowledgedLiveMode) }
        set { defaults.set(newValue, forKey: Keys.hasAcknowledgedLiveMode) }
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
        set {
            updateTranscriptionConfiguration(
                TranscriptionConfiguration(engine: newValue, modelID: selectedModelID)
            )
        }
    }

    public var selectedModelID: String {
        get { defaults.string(forKey: Keys.selectedModelID) ?? TranscriptionConfiguration.defaultWhisperModelID }
        set {
            updateTranscriptionConfiguration(
                TranscriptionConfiguration(engine: enginePreference, modelID: newValue)
            )
        }
    }

    public var transcriptionConfiguration: TranscriptionConfiguration {
        TranscriptionConfiguration(engine: enginePreference, modelID: selectedModelID).normalized
    }

    /// Updates model and engine as one logical operation so observers never
    /// construct an adapter for an intermediate configuration.
    public func selectModel(id: String, engine: EnginePreference) {
        updateTranscriptionConfiguration(TranscriptionConfiguration(engine: engine, modelID: id))
    }

    private func updateTranscriptionConfiguration(_ proposed: TranscriptionConfiguration) {
        let before = transcriptionConfiguration
        let normalized = proposed.normalized
        defaults.set(normalized.modelID, forKey: Keys.selectedModelID)
        defaults.set(normalized.engine.rawValue, forKey: Keys.engine)
        if normalized != before { notifyTranscriptionConfigurationChanged() }
    }

    private func notifyTranscriptionConfigurationChanged() {
        NotificationCenter.default.post(name: .nuviTranscriptionConfigurationDidChange, object: self)
    }

    private func notifyOutputPreferencesChanged() {
        NotificationCenter.default.post(name: .nuviOutputPreferencesDidChange, object: self)
    }

    private func notifyPresentationPreferencesChanged() {
        NotificationCenter.default.post(name: .nuviPresentationPreferencesDidChange, object: self)
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
        static let interfaceLanguage = "nuvi.interfaceLanguage"
        static let restoreClipboard = "nuvi.restoreClipboard"
        static let saveHistory = "nuvi.saveHistory"
        static let engine = "nuvi.engine"
        static let soundEffects = "nuvi.soundEffects"
        static let showPill = "nuvi.showPill"
        static let showMenuBarStatus = "nuvi.showMenuBarStatus"
        static let translationTarget = "nuvi.translationTarget"
        static let dictationDeliveryMode = "nuvi.dictationDeliveryMode"
        // Versioned because the original warning incorrectly said Parakeet
        // could not stream. Every user must see the corrected engine-specific
        // resource notice once.
        static let hasAcknowledgedLiveMode = "nuvi.hasAcknowledgedLiveModeV2"
        static let inputDeviceUID = "nuvi.inputDeviceUID"
        static let selectedModelID = "nuvi.selectedModelID"
        static let downloadedParakeet = "nuvi.downloadedParakeetModels"

        static func soundPreset(_ event: SoundEvent) -> String {
            "nuvi.sound.\(event.rawValue)"
        }
    }
}
