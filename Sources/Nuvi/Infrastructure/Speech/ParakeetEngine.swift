import Foundation
import AVFoundation
#if canImport(FluidAudio)
import FluidAudio
import CoreML
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
    private var modelSnapshot: ModelReadSnapshot?
    private var preparedModelID: String?

    public func prepare(locale: Locale) async throws {
        let modelID = selectedModelId
        if models != nil, manager != nil, modelSnapshot != nil, preparedModelID == modelID { return }
        do {
            let snapshot = try await ModelDownloadService.shared.prepareModelSnapshot(modelId: modelID)
            let version = Self.version(for: modelID)
            let loaded = try await Task.detached(priority: .userInitiated) {
                try Self.loadLocalModels(directory: snapshot.directory, version: version)
            }.value
            try Task.checkCancellation()
            let manager = AsrManager(config: .default)
            try await manager.loadModels(loaded)
            self.models = loaded
            self.manager = manager
            modelSnapshot = snapshot
            preparedModelID = modelID
        } catch is CancellationError { throw CancellationError() }
        catch {
            throw TranscriptionError.underlying("Parakeet could not load the local model. Delete and download it again in Settings. \(error.localizedDescription)")
        }
    }

    // Match pinned AsrModels.createModelSpecs/defaultConfiguration for catalog
    // v2/v3 INT8 models. AsrModels.load is NOT local-only: DownloadUtils catches
    // CoreML errors and deletes/re-downloads. Use public native constructors.
    static func localModelManifest(version: AsrModelVersion) -> [(String, MLComputeUnits)] {
        let units = AsrModels.defaultConfiguration().computeUnits
        return [(ModelNames.ASR.preprocessorFile, .cpuOnly),
                (ModelNames.ASR.encoderFile, units),
                (ModelNames.ASR.decoderFile, units),
                (version == .v2 ? ModelNames.ASR.jointFile : ModelNames.ASR.jointV3File, units)]
    }

    static func localVocabulary(at url: URL) throws -> [Int: String] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let vocabulary: [Int: String]
        if let values = object as? [String] { vocabulary = Dictionary(uniqueKeysWithValues: values.enumerated().map { ($0.offset, $0.element) }) }
        else if let values = object as? [String: String] {
            var decoded: [Int: String] = [:]
            for (key, value) in values { if let id = Int(key) { decoded[id] = value } }
            vocabulary = decoded
        } else { throw TranscriptionError.underlying("Invalid Parakeet vocabulary") }
        guard !vocabulary.isEmpty else { throw TranscriptionError.underlying("Empty Parakeet vocabulary") }
        return vocabulary
    }

    static func loadLocalModels(directory: URL, version: AsrModelVersion,
                                loader: (URL, MLModelConfiguration) throws -> MLModel = { try MLModel(contentsOf: $0, configuration: $1) }) throws -> AsrModels {
        let vocabulary = try localVocabulary(at: directory.appendingPathComponent(ModelNames.ASR.vocabularyFile))
        let manifest = localModelManifest(version: version)
        for (name, _) in manifest {
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) else {
                throw TranscriptionError.underlying("Missing Parakeet model file: \(name)")
            }
        }
        var loaded: [MLModel] = []
        for (name, units) in manifest {
            let configuration = AsrModels.defaultConfiguration()
            configuration.computeUnits = units
            loaded.append(try loader(directory.appendingPathComponent(name), configuration))
        }
        return AsrModels(encoder: loaded[1], preprocessor: loaded[0], decoder: loaded[2], joint: loaded[3],
                         configuration: AsrModels.defaultConfiguration(), vocabulary: vocabulary, version: version)
    }

    deinit {
        manager = nil
        models = nil
        modelSnapshot = nil
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
            let snapshot = modelSnapshot
            let task = Task {
                defer { withExtendedLifetime(snapshot) {} }
                do {
                    try Task.checkCancellation()
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
                        try Task.checkCancellation()
                        if let converted = converter.convert(buffer),
                           let channel = converted.floatChannelData {
                            let count = Int(converted.frameLength)
                            if samples.count + count > maxSamples {
                                throw TranscriptionError.underlying("Parakeet input exceeded 10 minute limit")
                            }
                            samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: count))
                        }
                    }

                    try Task.checkCancellation()
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
                    continuation.finish(throwing: Self.normalizedTranscriptionError(error))
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
            let snapshot = modelSnapshot
            let task = Task {
                defer { withExtendedLifetime(snapshot) {} }
                do {
                    try Task.checkCancellation()
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
                    var updatesTask: Task<Void, Never>?
                    let samples = try await SpeechStreamSessions.withCleanup(operation: {
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

                        updatesTask = Task {
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

                        try Task.checkCancellation()
                        _ = try await stream.finish()
                        try Task.checkCancellation()
                        return samples
                    }, cleanup: {
                        // FluidAudio finish does not close its update stream.
                        // Join the consumer on every exit, including setup failure.
                        await stream.cancel()
                        updatesTask?.cancel()
                        await updatesTask?.value
                    })

                    guard !samples.isEmpty else { throw NuviError.noAudioReceived }
                    // Preserve the settled quality of Standard mode: the short
                    // windows drive provisional text, then one full-context pass
                    // produces the authoritative final transcript.
                    var decoderState = try TdtDecoderState()
                    let result = try await manager.transcribe(samples, decoderState: &decoderState)
                    let final = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.yield(.final(final))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.normalizedTranscriptionError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    internal static func normalizedTranscriptionError(_ error: Error) -> Error {
        if error is CancellationError {
            return CancellationError()
        }
        if let coded = error as? NuviError {
            return coded
        }
        if let coded = error as? TranscriptionError {
            return coded
        }
        return TranscriptionError.underlying(String(describing: error))
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
