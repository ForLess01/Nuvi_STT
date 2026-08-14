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
        Self.normalizedModelID(customModelId ?? SettingsStore.shared.selectedModelID)
    }

    /// Internal observability seam for verifying factory wiring without loading
    /// FluidAudio models or widening the public engine contract.
    var configuredModelID: String { selectedModelId }

    public init(modelId: String? = nil) {
        self.customModelId = modelId
    }

    static func normalizedModelID(_ modelID: String) -> String {
        TranscriptionConfiguration(engine: .parakeet, modelID: modelID).normalized.modelID
    }

#if canImport(FluidAudio)
    private var manager: AsrManager?
    private var models: AsrModels?

    public func prepare(locale: Locale) async throws {
        do {
            let models = try await AsrModels.downloadAndLoad(version: Self.version(for: selectedModelId))
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            self.models = models
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

    public func transcribe(
        _ audio: AsyncStream<AVAudioPCMBuffer>,
        reportingPartials: Bool
    ) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        guard reportingPartials else { return transcribe(audio) }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let models, let manager else {
                        throw TranscriptionError.engineUnavailable("Parakeet not prepared")
                    }

                    // FluidAudio's stock `.streaming` preset waits for an 11 s
                    // center plus right context before its first update. Its
                    // `hypothesisChunkSeconds` value is currently not consumed,
                    // so the center window itself must be long enough for TDT to
                    // emit words. Sub-two-second windows complete successfully
                    // but commonly decode to an empty hypothesis.
                    let liveConfig = SlidingWindowAsrConfig(
                        chunkSeconds: 2.0,
                        hypothesisChunkSeconds: 2.0,
                        leftContextSeconds: 10.0,
                        rightContextSeconds: 0.25,
                        minContextForConfirmation: 4.0,
                        confirmationThreshold: 0.80
                    )
                    let stream = SlidingWindowAsrManager(config: liveConfig)
                    try await stream.loadModels(models)
                    let updates = await stream.transcriptionUpdates
                    try await stream.startStreaming(source: .microphone)

                    guard let target = AVAudioFormat(
                        commonFormat: .pcmFormatFloat32,
                        sampleRate: 16_000,
                        channels: 1,
                        interleaved: false
                    ) else {
                        throw TranscriptionError.underlying("Could not build 16kHz format")
                    }
                    let converter = BufferConverter(targetFormat: target)
                    var samples: [Float] = []
                    let maxSamples = 16_000 * 10 * 60

                    let updatesTask = Task {
                        for await update in updates {
                            guard !Task.isCancelled else { return }
                            // A final flush may decode no new tokens. FluidAudio
                            // temporarily clears its volatile tail for that empty
                            // update; forwarding it would visibly delete words
                            // just before Nuvi publishes the settled final result.
                            guard !update.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                                continue
                            }
                            let confirmed = await stream.confirmedTranscript
                            let volatile = await stream.volatileTranscript
                            let text = [confirmed, volatile]
                                .filter { !$0.isEmpty }
                                .joined(separator: " ")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if !text.isEmpty {
                                continuation.yield(.partial(text))
                            }
                        }
                    }

                    for await buffer in audio {
                        guard !Task.isCancelled else { throw CancellationError() }
                        await stream.streamAudio(buffer)
                        if let converted = converter.convert(buffer),
                           let channel = converted.floatChannelData {
                            let count = Int(converted.frameLength)
                            if samples.count + count > maxSamples {
                                throw TranscriptionError.underlying(
                                    "Parakeet input exceeded 10 minute limit"
                                )
                            }
                            samples.append(
                                contentsOf: UnsafeBufferPointer(start: channel[0], count: count)
                            )
                        }
                    }

                    _ = try await stream.finish()
                    // `finish()` closes audio input but intentionally leaves the
                    // updates stream open for callers that inspect the result.
                    // Close it explicitly so the consumer task cannot outlive a
                    // Nuvi session (or keep a test process alive indefinitely).
                    await stream.cancel()
                    updatesTask.cancel()
                    _ = await updatesTask.result

                    guard !samples.isEmpty else { throw NuviError.noAudioReceived }
                    // Preserve the settled quality of Standard mode: the short
                    // windows drive provisional text, then one full-context pass
                    // produces the authoritative final transcript.
                    var decoderState = try TdtDecoderState()
                    let result = try await manager.transcribe(samples, decoderState: &decoderState)
                    let final = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.yield(.final(final))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(
                        throwing: TranscriptionError.underlying(String(describing: error))
                    )
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
