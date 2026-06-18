import Foundation

/// The ONE place that decides which adapter the app uses, driven by the user's
/// engine preference. `auto` builds the hybrid composite (native first, Whisper
/// fallback). Everything else returns a single adapter.
public enum TranscriptionEngineFactory {
    public static func make(preference: EnginePreference) -> TranscriptionEngine {
        switch preference {
        case .speechAnalyzer:
            return SpeechAnalyzerEngine()
        case .whisperKit:
            return WhisperKitEngine()
        case .parakeet:
            return ParakeetEngine()
        case .auto:
            return HybridTranscriptionEngine(
                primary: SpeechAnalyzerEngine(),
                fallback: WhisperKitEngine()
            )
        }
    }

    public static func makeDefault() -> TranscriptionEngine {
        make(preference: SettingsStore.shared.enginePreference)
    }
}
