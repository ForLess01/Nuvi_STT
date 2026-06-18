import Foundation
import AVFoundation
#if canImport(FluidAudio)
import FluidAudio
#endif

/// Adapter for Parakeet TDT ASR running on CoreML via FluidAudio.
///
/// Compiled only when the FluidAudio package is present (`#if canImport`), so the
/// project always builds. FluidAudio owns model download and on-disk caching
/// internally — unlike WhisperKit, there is no direct `.zip` URL to fetch.
///
/// Strategy mirrors `WhisperKitEngine`: Parakeet is batch-oriented, so we
/// accumulate the mic stream into a 16kHz mono Float buffer and transcribe once
/// on stop, emitting a single final result.
public final class ParakeetEngine: TranscriptionEngine, @unchecked Sendable {
    public let identifier = "parakeet"

    /// Explicit Parakeet model id. If not provided, falls back dynamically to the
    /// model selected in SettingsStore.
    private let customModelId: String?

    private var selectedModelId: String {
        customModelId ?? SettingsStore.shared.selectedModelID
    }

    public init(modelId: String? = nil) {
        self.customModelId = modelId
    }

#if canImport(FluidAudio)
    private var manager: AsrManager?

    public func prepare(locale: Locale) async throws {
        do {
            let models = try await AsrModels.downloadAndLoad(version: Self.version(for: selectedModelId))
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            self.manager = manager
        } catch {
            throw TranscriptionError.underlying("Parakeet init failed: \(error.localizedDescription)")
        }
    }

    /// Maps a catalog model id to a FluidAudio model version. "v2" → English-only
    /// (highest recall); everything else defaults to "v3" (multilingual).
    private static func version(for modelId: String) -> AsrModelVersion {
        modelId.contains("v2") ? .v2 : .v3
    }

    public func transcribe(
        _ audio: AsyncStream<AVAudioPCMBuffer>
    ) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let manager else {
                        throw TranscriptionError.engineUnavailable("Parakeet not prepared")
                    }

                    // FluidAudio wants 16kHz mono Float samples.
                    guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                     sampleRate: 16_000,
                                                     channels: 1,
                                                     interleaved: false) else {
                        throw TranscriptionError.underlying("Could not build 16kHz format")
                    }
                    let converter = BufferConverter(targetFormat: target)

                    var samples: [Float] = []
                    let maxSamples = 16_000 * 10 * 60 // 10 minutes at 16 kHz mono.
                    for await buffer in audio {
                        if let converted = converter.convert(buffer),
                           let channel = converted.floatChannelData {
                            let count = Int(converted.frameLength)
                            if samples.count + count > maxSamples {
                                throw TranscriptionError.underlying("Parakeet input exceeded 10 minute limit")
                            }
                            samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: count))
                        }
                    }

                    guard !samples.isEmpty else {
                        NSLog("Nuvi/parakeet: no audio reached the engine")
                        continuation.finish(throwing: NuviError.noAudioReceived)
                        return
                    }

                    // TDT transcription threads a decoder state; for a one-shot
                    // batch we create a fresh state and discard it after.
                    var decoderState = try TdtDecoderState()
                    let result = try await manager.transcribe(samples, decoderState: &decoderState)
                    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

                    continuation.yield(.final(text))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: TranscriptionError.underlying(String(describing: error)))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
#else
    public func prepare(locale: Locale) async throws {
        throw TranscriptionError.engineUnavailable(
            "FluidAudio package not added. Add FluidAudio to Package.swift to enable Parakeet."
        )
    }

    public func transcribe(
        _ audio: AsyncStream<AVAudioPCMBuffer>
    ) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(
                throwing: TranscriptionError.engineUnavailable("FluidAudio package not added")
            )
        }
    }
#endif
}
