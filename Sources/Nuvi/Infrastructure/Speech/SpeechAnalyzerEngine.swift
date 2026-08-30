import Foundation
import AVFoundation
import Speech

/// Primary adapter: Apple's native on-device SpeechAnalyzer (macOS 26+).
///
/// Lowest resource footprint of the options we benchmarked, best Spanish WER on
/// clean dictation, and no large model download — the asset is system-managed.
/// This is the default Nuvi ships with.
public final class SpeechAnalyzerEngine: TranscriptionEngine, @unchecked Sendable {
    public let identifier = "speech-analyzer"

    /// Preparation dependencies keep the system Speech APIs in one live
    /// adapter while allowing deterministic tests for authorization and asset
    /// postconditions without requesting real permissions or downloads.
    internal struct PreparationHooks {
        let requestAuthorization: () async -> SFSpeechRecognizerAuthorizationStatus
        let supportedLocales: () async -> [Locale]
        let installedLocales: () async -> [Locale]
        let reserve: (Locale) async throws -> Void
        let installMissingAsset: (Locale) async throws -> Void

        static var live: PreparationHooks {
            PreparationHooks(
                requestAuthorization: {
                    await SpeechAnalyzerEngine.requestSpeechRecognitionAuthorizationIfNeeded()
                },
                supportedLocales: {
                    await SpeechTranscriber.supportedLocales
                },
                installedLocales: {
                    await SpeechTranscriber.installedLocales
                },
                reserve: { locale in
                    _ = try await AssetInventory.reserve(locale: locale)
                },
                installMissingAsset: { locale in
                    let transcriber = SpeechAnalyzerEngine.makePreparationTranscriber(locale: locale)
                    let installationRequest = try await AssetInventory.assetInstallationRequest(
                        supporting: [transcriber]
                    )
                    if let request = installationRequest {
                        let target = locale.identifier(.bcp47)
                        NSLog("Nuvi/speech: installing speech asset for \(target)")
                        try await request.downloadAndInstall()
                    } else {
                        NSLog("Nuvi/speech: asset installation request unavailable")
                    }
                }
            )
        }
    }

    internal enum AnalyzerInputYieldResult: Equatable {
        case enqueued
        case dropped
        case terminated
    }

    /// The input queue stays bounded and drops the newest converted slice when
    /// the analyzer falls behind, preserving temporal order of queued audio.
    internal static let analyzerInputBufferCapacity = 8

    private var locale: Locale = Locale(identifier: "es-ES")
    private let preparationHooks: PreparationHooks

    public init() {
        preparationHooks = .live
    }

    internal init(preparationHooks: PreparationHooks) {
        self.preparationHooks = preparationHooks
    }

    public func prepare(locale: Locale) async throws {
        self.locale = locale

        let authorization = await preparationHooks.requestAuthorization()
        guard authorization == .authorized else {
            throw TranscriptionError.engineUnavailable(Self.describeSpeechAuthorization(authorization))
        }

        let target = locale.identifier(.bcp47)

        // Match by exact BCP-47, falling back to language code (es-ES ≈ es-419).
        let supported = await preparationHooks.supportedLocales()
        NSLog("Nuvi/speech: supportedLocales=\(supported.count), target=\(target)")
        let isSupported = Self.localeMatches(locale, in: supported)
        guard isSupported else { throw TranscriptionError.unsupportedLocale(locale.identifier) }

        // Reserving is best-effort: never fail prepare over it. Still, log failures —
        // a swallowed reservation error here is exactly the kind of silent gap that
        // makes "mic opens but never transcribes" impossible to diagnose.
        do {
            try await preparationHooks.reserve(locale)
        } catch {
            NSLog("Nuvi/speech: locale reservation failed (continuing): \(String(describing: error))")
        }

        let installed = await preparationHooks.installedLocales()
        NSLog("Nuvi/speech: installedLocales=\(installed.count), target=\(target)")
        let isInstalled = Self.localeMatches(locale, in: installed)
        if !isInstalled {
            try await preparationHooks.installMissingAsset(locale)
            // A completed request (or a nil request) is not the postcondition;
            // only the framework's installed-locale inventory can confirm it.
            let postInstallLocales = await preparationHooks.installedLocales()
            let confirmed = Self.localeMatches(locale, in: postInstallLocales)
            NSLog("Nuvi/speech: asset postcondition target=\(target), installed=\(confirmed)")
            guard confirmed else {
                NSLog("Nuvi/speech: speech asset unavailable after installation attempt for \(target)")
                throw TranscriptionError.assetUnavailable
            }
            NSLog("Nuvi/speech: installed speech asset for \(target)")
        }
    }

    public func transcribe(
        _ audio: AsyncStream<AVAudioPCMBuffer>
    ) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    let transcriber = self.makeTranscriber(volatile: true)
                    let analyzer = SpeechAnalyzer(modules: [transcriber])
                    let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
                    if let analyzerFormat {
                        NSLog("Nuvi/speech: analyzer format sampleRate=\(analyzerFormat.sampleRate), channels=\(analyzerFormat.channelCount)")
                    } else {
                        NSLog("Nuvi/speech: analyzer format unavailable, using source format")
                    }

                    let (inputStream, inputCont) = AsyncStream<AnalyzerInput>.makeStream(
                        bufferingPolicy: .bufferingOldest(Self.analyzerInputBufferCapacity)
                    )
                    let analyzerTask = Task {
                        try await analyzer.start(inputSequence: inputStream)
                    }

                    // Pump mic buffers into the analyzer, converting on the way.
                    // `audioSeen` lets us tell "the mic delivered nothing" (a real
                    // failure) apart from "the user just didn't speak" (silence).
                    let audioSeen = AtomicFlag()
                    let pump = Task {
                        let converter = BufferConverter(targetFormat: analyzerFormat)
                        var droppedInputCount = 0
                        pumpLoop: for await buffer in audio {
                            if let converted = converter.convert(buffer) {
                                audioSeen.set()
                                switch Self.yieldAnalyzerInput(
                                    AnalyzerInput(buffer: converted),
                                    into: inputCont,
                                    droppedCount: &droppedInputCount
                                ) {
                                case .enqueued, .dropped:
                                    break
                                case .terminated:
                                    break pumpLoop
                                }
                            }
                        }
                        inputCont.finish()
                        if droppedInputCount > 0 {
                            NSLog("Nuvi/speech: dropped \(droppedInputCount) newest analyzer input buffers (bounded queue)")
                        }
                        do {
                            try await analyzer.finalizeAndFinishThroughEndOfInput()
                        } catch {
                            NSLog("Nuvi/speech: finalize failed: \(String(describing: error))")
                        }
                    }

                    defer {
                        analyzerTask.cancel()
                        pump.cancel()
                    }

                    var emittedResult = false
                    for try await result in transcriber.results {
                        emittedResult = true
                        let text = String(result.text.characters)
                        continuation.yield(result.isFinal ? .final(text) : .partial(text))
                    }

                    // pump has finished by now, so the flag is settled.
                    await pump.value
                    try await analyzerTask.value

                    if !emittedResult && !audioSeen.value {
                        NSLog("Nuvi/speech: no audio reached the analyzer")
                        continuation.finish(throwing: NuviError.noAudioReceived)
                        return
                    }
                    if !emittedResult {
                        NSLog("Nuvi/speech: transcriber finished without results (silence)")
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.normalizedTranscriptionError(error))
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    private static func requestSpeechRecognitionAuthorizationIfNeeded() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private static func describeSpeechAuthorization(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "Speech recognition access not determined"
        case .denied:
            return "Speech recognition access denied"
        case .restricted:
            return "Speech recognition is restricted on this Mac"
        case .authorized:
            return "Speech recognition authorized"
        @unknown default:
            return "Speech recognition access unavailable"
        }
    }

    internal static func localeMatches(_ locale: Locale, in locales: [Locale]) -> Bool {
        let target = locale.identifier(.bcp47)
        let language = locale.language.languageCode?.identifier
        return locales.contains { candidate in
            candidate.identifier(.bcp47) == target
                || (language != nil && candidate.language.languageCode?.identifier == language)
        }
    }

    internal static func yieldAnalyzerInput(
        _ input: AnalyzerInput,
        into continuation: AsyncStream<AnalyzerInput>.Continuation,
        droppedCount: inout Int
    ) -> AnalyzerInputYieldResult {
        switch continuation.yield(input) {
        case .enqueued:
            return .enqueued
        case .dropped:
            droppedCount += 1
            return .dropped
        case .terminated:
            return .terminated
        @unknown default:
            return .terminated
        }
    }

    internal static func isCancellationError(_ error: Error) -> Bool {
        error is CancellationError
    }

    internal static func normalizedTranscriptionError(_ error: Error) -> Error {
        if isCancellationError(error) {
            return CancellationError()
        }
        if let coded = error as? NuviError {
            return coded
        }
        return TranscriptionError.underlying(String(describing: error))
    }

    private static func makePreparationTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
    }

    private func makeTranscriber(volatile: Bool) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: volatile ? [.volatileResults] : [],
            attributeOptions: []
        )
    }
}
