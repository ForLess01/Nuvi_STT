import Foundation

/// The ONE place that decides which adapter the app uses, driven by the user's
/// engine preference. `auto` builds the hybrid composite (native first, Whisper
/// fallback). Everything else returns a single adapter.
public enum TranscriptionEngineFactory {
    public static func make(configuration: TranscriptionConfiguration) -> TranscriptionEngine {
        switch configuration.engine {
        case .speechAnalyzer:
            return SpeechAnalyzerEngine()
        case .whisperKit:
            return WhisperKitEngine(modelName: configuration.modelID)
        case .parakeet:
            return ParakeetEngine(modelId: configuration.modelID)
        case .auto:
            return HybridTranscriptionEngine(
                primary: SpeechAnalyzerEngine(),
                fallback: WhisperKitEngine(modelName: configuration.modelID)
            )
        }
    }

    public static func makeDefault() -> TranscriptionEngine {
        make(configuration: SettingsStore.shared.transcriptionConfiguration)
    }
}
