import Foundation
import AVFoundation

/// The PORT. The whole application talks to transcription exclusively through
/// this protocol — it never references SpeechAnalyzer or WhisperKit directly.
///
/// That is what makes the "hybrid" strategy clean instead of a tangle: each
/// engine is an adapter behind this single contract, and swapping or routing
/// between them is a decision made in one factory, not scattered across the UI.
public protocol TranscriptionEngine: AnyObject, Sendable {
    /// Stable identifier for diagnostics / settings (e.g. "speech-analyzer").
    var identifier: String { get }

    /// Prepare for a locale and engine configuration: download/allocate models
    /// if the adapter needs to. Called once before the first session for that
    /// configuration and locale pair.
    func prepare(locale: Locale) async throws

    /// Consume a stream of microphone buffers and emit transcription events.
    /// The returned stream finishes after the final event once `audio` ends.
    func transcribe(
        _ audio: AsyncStream<AVAudioPCMBuffer>
    ) -> AsyncThrowingStream<TranscriptionEvent, Error>

    /// Consume microphone buffers while optionally favoring an incremental
    /// recognition path. Engines that are already streaming can keep their
    /// normal implementation; batch engines may opt into a live adapter.
    func transcribe(
        _ audio: AsyncStream<AVAudioPCMBuffer>,
        reportingPartials: Bool
    ) -> AsyncThrowingStream<TranscriptionEvent, Error>
}

public extension TranscriptionEngine {
    func transcribe(
        _ audio: AsyncStream<AVAudioPCMBuffer>,
        reportingPartials: Bool
    ) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        transcribe(audio)
    }
}
