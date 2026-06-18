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
/// Strategy: WhisperKit is batch-oriented, so we accumulate the mic stream into a
/// 16kHz mono Float buffer and transcribe once on stop, emitting a final result.
/// That is exactly what a "fallback for hard audio" needs — robustness over
/// streaming partials.
public final class WhisperKitEngine: TranscriptionEngine, @unchecked Sendable {
    public let identifier = "whisperkit"

    /// Explicit WhisperKit model variant. If not provided, falls back dynamically
    /// to the model selected in SettingsStore.
    private let customModelName: String?
    
    private var modelName: String {
        customModelName ?? SettingsStore.shared.selectedModelID
    }

    public init(modelName: String? = nil) {
        self.customModelName = modelName
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
                try? Self.resetAppOwnedWhisperCache()
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

    private static func resetAppOwnedWhisperCache() throws {
        let downloadBase = try ModelStorage.whisperKitBase()
        if FileManager.default.fileExists(atPath: downloadBase.path) {
            try FileManager.default.removeItem(at: downloadBase)
        }
        try FileManager.default.createDirectory(at: downloadBase, withIntermediateDirectories: true)
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

                    var samples: [Float] = []
                    let maxSamples = 16_000 * 10 * 60 // 10 minutes at 16 kHz mono.
                    for await buffer in audio {
                        if let converted = converter.convert(buffer),
                           let channel = converted.floatChannelData {
                            let count = Int(converted.frameLength)
                            if samples.count + count > maxSamples {
                                throw TranscriptionError.underlying("WhisperKit input exceeded 10 minute limit")
                            }
                            samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: count))
                        }
                    }

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
                    continuation.finish(throwing: TranscriptionError.underlying(String(describing: error)))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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
