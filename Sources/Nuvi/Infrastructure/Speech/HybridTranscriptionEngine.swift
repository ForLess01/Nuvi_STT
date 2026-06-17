import Foundation
import AVFoundation

/// The hybrid, done the RIGHT way: a composite that is itself a
/// `TranscriptionEngine`. It tries the primary (SpeechAnalyzer) and transparently
/// falls back to the secondary (WhisperKit) when the primary can't serve a
/// locale or its asset is unavailable.
///
/// The rest of the app sees one engine. The routing decision lives here and only
/// here — that is the entire payoff of the port abstraction.
public final class HybridTranscriptionEngine: TranscriptionEngine, @unchecked Sendable {
    public let identifier = "hybrid"

    private let primary: TranscriptionEngine
    private let fallback: TranscriptionEngine
    private var active: TranscriptionEngine

    public init(primary: TranscriptionEngine, fallback: TranscriptionEngine) {
        self.primary = primary
        self.fallback = fallback
        self.active = primary
    }

    public func prepare(locale: Locale) async throws {
        do {
            try await primary.prepare(locale: locale)
            active = primary
        } catch {
            // Primary can't handle this locale/asset — promote the fallback.
            try await fallback.prepare(locale: locale)
            active = fallback
        }
    }

    public func transcribe(
        _ audio: AsyncStream<AVAudioPCMBuffer>
    ) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        active.transcribe(audio)
    }
}
