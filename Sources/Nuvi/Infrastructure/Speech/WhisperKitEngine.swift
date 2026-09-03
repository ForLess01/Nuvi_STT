import Foundation
import AVFoundation
#if canImport(WhisperKit)
import WhisperKit
#endif

/// Fallback adapter: Whisper running natively on CoreML via WhisperKit.
///
/// The real implementation is compiled only when the WhisperKit package is
/// present (`#if canImport`), so the project always builds. To enable it:
///   1. Add to Package.swift:
///        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0")
///      and the product `.product(name: "WhisperKit", package: "argmax-oss-swift")`.
///   2. Rebuild. `canImport(WhisperKit)` flips on and this becomes live.
///
/// Standard mode runs one settled pass after capture. Live mode periodically
/// decodes a bounded rolling 16 kHz window and emits provisional revisions, so
/// all currently catalogued Whisper model sizes participate in progressive delivery.
internal struct RollingAudioWindow {
    let capacity: Int
    private var storage: [Float]
    private var head = 0
    private(set) var count = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage = Array(repeating: 0, count: capacity)
    }

    mutating func append(contentsOf source: [Float]) {
        source.withUnsafeBufferPointer { append(contentsOf: $0) }
    }

    mutating func append(contentsOf source: UnsafeBufferPointer<Float>) {
        guard !source.isEmpty else { return }

        if source.count >= capacity {
            let start = source.count - capacity
            for index in 0..<capacity {
                storage[index] = source[start + index]
            }
            head = 0
            count = capacity
            return
        }

        let overflow = max(0, count + source.count - capacity)
        if overflow > 0 {
            head = (head + overflow) % capacity
            count -= overflow
        }

        for value in source {
            let tail = (head + count) % capacity
            storage[tail] = value
            count += 1
        }
    }

    func snapshot() -> [Float] {
        guard count > 0 else { return [] }
        var result: [Float] = []
        result.reserveCapacity(count)
        for offset in 0..<count {
            result.append(storage[(head + offset) % capacity])
        }
        return result
    }
}

public final class WhisperKitEngine: TranscriptionEngine, @unchecked Sendable {
    public let identifier = "whisperkit"

    /// Explicit WhisperKit model variant. If not provided, falls back dynamically
    /// to the model selected in SettingsStore.
    private let customModelName: String?
    
    private var modelName: String {
        Self.normalizedModelName(customModelName ?? SettingsStore.shared.selectedModelID)
    }

    /// Internal observability seam for verifying factory wiring without loading
    /// WhisperKit models or widening the public engine contract.
    var configuredModelID: String { modelName }

    public init(modelName: String? = nil) {
        self.customModelName = modelName
    }

    static func normalizedModelName(_ modelName: String) -> String {
        TranscriptionConfiguration(engine: .whisperKit, modelID: modelName).normalized.modelID
    }

#if canImport(WhisperKit)
    private var pipe: WhisperKit?
    private var languageCode: String = "es"

    public func prepare(locale: Locale) async throws {
        languageCode = locale.language.languageCode?.identifier ?? "es"
        do {
            pipe = try await makePipeline()
        } catch {
            if Self.isRecoverableMetadataError(error) {
                try? Self.resetModelCache(for: modelName)
                do {
                    pipe = try await makePipeline()
                    return
                } catch {
                    throw TranscriptionError.underlying("WhisperKit init failed after cache reset: \(error.localizedDescription)")
                }
            }
            throw TranscriptionError.underlying("WhisperKit init failed: \(error.localizedDescription)")
        }
    }

    private func makePipeline() async throws -> WhisperKit {
        try await WhisperKit(
            WhisperKitConfig(
                model: modelName,
                downloadBase: ModelStorage.whisperKitBase(),
                verbose: false,
                logLevel: .error
            )
        )
    }

    private static func resetModelCache(for modelName: String) throws {
        let downloadBase = try ModelStorage.whisperKitBase()
        guard FileManager.default.fileExists(atPath: downloadBase.path) else { return }
        if let enumerator = FileManager.default.enumerator(at: downloadBase, includingPropertiesForKeys: nil) {
            var toRemove: [URL] = []
            for case let fileURL as URL in enumerator where fileURL.lastPathComponent == "config.json" {
                let dir = fileURL.deletingLastPathComponent()
                if dir.lastPathComponent == modelName {
                    toRemove.append(dir)
                }
            }
            for dir in toRemove {
                try? FileManager.default.removeItem(at: dir)
            }
        }
    }

    private static func isRecoverableMetadataError(_ error: Error) -> Bool {
        let description = String(describing: error).lowercased()
        let localized = error.localizedDescription.lowercased()
        return description.contains("invalidmetadataerror")
            || localized.contains("invalid metadata")
            || description.contains("metadata")
            || localized.contains("metadata")
    }

    public func transcribe(
        _ audio: AsyncStream<AVAudioPCMBuffer>
    ) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try Task.checkCancellation()
                    guard let pipe else {
                        throw TranscriptionError.engineUnavailable("WhisperKit not prepared")
                    }

                    // WhisperKit wants 16kHz mono Float samples.
                    guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                     sampleRate: 16_000,
                                                     channels: 1,
                                                     interleaved: false) else {
                        throw TranscriptionError.underlying("Could not build 16kHz format")
                    }
                    let converter = BufferConverter(targetFormat: target)

                    // Keep the complete bounded session for the authoritative
                    // final pass; LIVE decodes only the rolling window below.
                    var samples: [Float] = []
                    let maxSamples = 16_000 * 10 * 60 // 10 minutes at 16 kHz mono.
                    for await buffer in audio {
                        try Task.checkCancellation()
                        if let converted = converter.convert(buffer),
                           let channel = converted.floatChannelData {
                            let count = Int(converted.frameLength)
                            if samples.count + count > maxSamples {
                                throw TranscriptionError.underlying("WhisperKit input exceeded 10 minute limit")
                            }
                            samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: count))
                        }
                    }

                    try Task.checkCancellation()
                    guard !samples.isEmpty else {
                        NSLog("Nuvi/whisperkit: no audio reached the engine")
                        continuation.finish(throwing: NuviError.noAudioReceived)
                        return
                    }

                    let options = DecodingOptions(language: languageCode)
                    let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
                    let text = results.map(\.text).joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)

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
            let task = Task {
                do {
                    try Task.checkCancellation()
                    guard let pipe else {
                        throw TranscriptionError.engineUnavailable("WhisperKit not prepared")
                    }
                    guard let target = AVAudioFormat(
                        commonFormat: .pcmFormatFloat32,
                        sampleRate: 16_000,
                        channels: 1,
                        interleaved: false
                    ) else {
                        throw TranscriptionError.underlying("Could not build 16kHz format")
                    }

                    let converter = BufferConverter(targetFormat: target)
                    let options = DecodingOptions(language: languageCode)
                    let cadence = Self.liveCadenceSamples(for: modelName)
                    let minimumHypothesisSamples = 16_000 * 2
                    let maxSamples = 16_000 * 10 * 60
                    var nextHypothesisAt = minimumHypothesisSamples
                    // The full session is retained for the settled final pass;
                    // provisional decodes use only the bounded rolling window.
                    var samples: [Float] = []
                    var liveWindow = RollingAudioWindow(capacity: Self.liveWindowSamples)
                    var lastPartial = ""

                    for await buffer in audio {
                        guard !Task.isCancelled else { throw CancellationError() }
                        guard let converted = converter.convert(buffer),
                              let channel = converted.floatChannelData else { continue }
                        let count = Int(converted.frameLength)
                        if samples.count + count > maxSamples {
                            throw TranscriptionError.underlying(
                                "WhisperKit input exceeded 10 minute limit"
                            )
                        }
                        let source = UnsafeBufferPointer(start: channel[0], count: count)
                        samples.append(
                            contentsOf: source
                        )
                        liveWindow.append(contentsOf: source)

                        guard samples.count >= nextHypothesisAt else { continue }
                        let results = try await pipe.transcribe(
                            audioArray: liveWindow.snapshot(),
                            decodeOptions: options
                        )
                        let hypothesis = Self.joinedText(results)
                        // The controller's LiveTranscriptAssembler keeps the
                        // prior provisional text and de-duplicates overlap when
                        // this rolling window advances.
                        if !hypothesis.isEmpty, hypothesis != lastPartial {
                            lastPartial = hypothesis
                            continuation.yield(.partial(hypothesis))
                        }
                        nextHypothesisAt = samples.count + cadence
                    }

                    try Task.checkCancellation()
                    guard !samples.isEmpty else { throw NuviError.noAudioReceived }
                    let results = try await pipe.transcribe(
                        audioArray: samples,
                        decodeOptions: options
                    )
                    continuation.yield(.final(Self.joinedText(results)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.normalizedTranscriptionError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func liveCadenceSamples(for modelID: String) -> Int {
        let seconds: Double
        if modelID.contains("large") || modelID.contains("medium") {
            seconds = 3.0
        } else if modelID.contains("small") {
            seconds = 2.0
        } else {
            seconds = 1.5
        }
        return Int(16_000 * seconds)
    }

    /// Whisper's native feature extractor uses a 30-second window. Keeping the
    /// live decode input at that bound avoids re-decoding the entire session;
    /// Standard mode still uses the complete `samples` buffer for its final pass.
    internal static let liveWindowSamples = 16_000 * 30

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

    private static func joinedText(_ results: [TranscriptionResult]) -> String {
        results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
#else
    public func prepare(locale: Locale) async throws {
        throw TranscriptionError.engineUnavailable(
            "WhisperKit package not added. Add argmax-oss-swift to Package.swift to enable the fallback."
        )
    }

    public func transcribe(
        _ audio: AsyncStream<AVAudioPCMBuffer>
    ) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(
                throwing: TranscriptionError.engineUnavailable("WhisperKit package not added")
            )
        }
    }
#endif
}
