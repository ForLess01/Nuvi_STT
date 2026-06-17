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

    private var locale: Locale = Locale(identifier: "es-ES")

    public init() {}

    public func prepare(locale: Locale) async throws {
        self.locale = locale

        let authorization = await Self.requestSpeechRecognitionAuthorizationIfNeeded()
        guard authorization == .authorized else {
            throw TranscriptionError.engineUnavailable(Self.describeSpeechAuthorization(authorization))
        }

        let target = locale.identifier(.bcp47)
        let lang = locale.language.languageCode?.identifier

        // Match by exact BCP-47, falling back to language code (es-ES ≈ es-419).
        let supported = await SpeechTranscriber.supportedLocales
        NSLog("Nuvi/speech: supportedLocales=\(supported.count), target=\(target)")
        let isSupported = supported.contains { $0.identifier(.bcp47) == target }
            || (lang != nil && supported.contains { $0.language.languageCode?.identifier == lang })
        guard isSupported else { throw TranscriptionError.unsupportedLocale(locale.identifier) }

        // Reserving is best-effort: never fail prepare over it. Still, log failures —
        // a swallowed reservation error here is exactly the kind of silent gap that
        // makes "mic opens but never transcribes" impossible to diagnose.
        do {
            _ = try await AssetInventory.reserve(locale: locale)
        } catch {
            NSLog("Nuvi/speech: locale reservation failed (continuing): \(String(describing: error))")
        }

        let installed = await SpeechTranscriber.installedLocales
        NSLog("Nuvi/speech: installedLocales=\(installed.count), target=\(target)")
        let isInstalled = installed.contains { $0.identifier(.bcp47) == target }
            || (lang != nil && installed.contains { $0.language.languageCode?.identifier == lang })
        if !isInstalled {
            let transcriber = makeTranscriber(volatile: false)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                NSLog("Nuvi/speech: installing speech asset for \(target)")
                try await request.downloadAndInstall()
                NSLog("Nuvi/speech: installed speech asset for \(target)")
            }
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

                    let (inputStream, inputCont) = AsyncStream<AnalyzerInput>.makeStream()
                    let analyzerTask = Task {
                        try await analyzer.start(inputSequence: inputStream)
                    }

                    // Pump mic buffers into the analyzer, converting on the way.
                    // `audioSeen` lets us tell "the mic delivered nothing" (a real
                    // failure) apart from "the user just didn't speak" (silence).
                    let audioSeen = AtomicFlag()
                    let pump = Task {
                        let converter = BufferConverter(targetFormat: analyzerFormat)
                        for await buffer in audio {
                            if let converted = converter.convert(buffer) {
                                audioSeen.set()
                                inputCont.yield(AnalyzerInput(buffer: converted))
                            }
                        }
                        inputCont.finish()
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
                } catch let coded as NuviError {
                    continuation.finish(throwing: coded)
                } catch {
                    continuation.finish(throwing: TranscriptionError.underlying(String(describing: error)))
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

    private func makeTranscriber(volatile: Bool) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: volatile ? [.volatileResults] : [],
            attributeOptions: []
        )
    }
}
