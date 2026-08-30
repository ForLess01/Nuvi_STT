import XCTest
import AVFoundation
import Speech
@testable import Nuvi

final class SpeechAnalyzerEngineTests: XCTestCase {
    func testAnalyzerInputQueueCountsDropsAndPreservesOldestSlices() async throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingOldest(2)
        )
        var droppedCount = 0

        XCTAssertEqual(
            SpeechAnalyzerEngine.yieldAnalyzerInput(
                AnalyzerInput(buffer: makeBuffer(format: format, value: 1)),
                into: continuation,
                droppedCount: &droppedCount
            ),
            .enqueued
        )
        XCTAssertEqual(
            SpeechAnalyzerEngine.yieldAnalyzerInput(
                AnalyzerInput(buffer: makeBuffer(format: format, value: 2)),
                into: continuation,
                droppedCount: &droppedCount
            ),
            .enqueued
        )
        XCTAssertEqual(
            SpeechAnalyzerEngine.yieldAnalyzerInput(
                AnalyzerInput(buffer: makeBuffer(format: format, value: 3)),
                into: continuation,
                droppedCount: &droppedCount
            ),
            .dropped
        )

        XCTAssertEqual(droppedCount, 1)
        var iterator = stream.makeAsyncIterator()
        let firstValue = await iterator.next()
        let secondValue = await iterator.next()
        let first = try XCTUnwrap(firstValue)
        let second = try XCTUnwrap(secondValue)
        XCTAssertEqual(first.buffer.floatChannelData![0][0], 1)
        XCTAssertEqual(second.buffer.floatChannelData![0][0], 2)
        continuation.finish()
    }

    func testAnalyzerInputQueueReportsTerminationWithoutCountingItAsDrop() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let (_, continuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingOldest(1)
        )
        continuation.finish()
        var droppedCount = 0

        XCTAssertEqual(
            SpeechAnalyzerEngine.yieldAnalyzerInput(
                AnalyzerInput(buffer: makeBuffer(format: format, value: 1)),
                into: continuation,
                droppedCount: &droppedCount
            ),
            .terminated
        )
        XCTAssertEqual(droppedCount, 0)
    }

    func testPrepareFailsWhenMissingAssetHasNoInstalledPostcondition() async {
        let locale = Locale(identifier: "es-ES")
        let installedLocales = InstalledLocalesStore()
        let hooks = SpeechAnalyzerEngine.PreparationHooks(
            requestAuthorization: { .authorized },
            supportedLocales: { [locale] },
            installedLocales: { await installedLocales.read() },
            reserve: { _ in },
            // Models an unavailable installation request without depending on
            // constructing framework-owned AssetInventory request values.
            installMissingAsset: { _ in }
        )
        let engine = SpeechAnalyzerEngine(preparationHooks: hooks)

        do {
            try await engine.prepare(locale: locale)
            XCTFail("prepare must fail when the asset is not confirmed installed")
        } catch let error as TranscriptionError {
            guard case .assetUnavailable = error else {
                XCTFail("unexpected transcription error: \(error)")
                return
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let readCount = await installedLocales.readCount()
        XCTAssertEqual(readCount, 2)
    }

    func testPrepareAcceptsMissingAssetOnlyWhenPostconditionIsConfirmed() async throws {
        let locale = Locale(identifier: "es-ES")
        let installedLocales = InstalledLocalesStore()
        let hooks = SpeechAnalyzerEngine.PreparationHooks(
            requestAuthorization: { .authorized },
            supportedLocales: { [locale] },
            installedLocales: { await installedLocales.read() },
            reserve: { _ in },
            installMissingAsset: { locale in await installedLocales.install(locale) }
        )
        let engine = SpeechAnalyzerEngine(preparationHooks: hooks)

        try await engine.prepare(locale: locale)
        let readCount = await installedLocales.readCount()
        XCTAssertEqual(readCount, 2)
    }

    func testCancellationIsKeptDistinctFromUnderlyingFailures() {
        let cancellation = SpeechAnalyzerEngine.normalizedTranscriptionError(CancellationError())
        XCTAssertTrue(cancellation is CancellationError)

        let underlying = SpeechAnalyzerEngine.normalizedTranscriptionError(TestSpeechError.failed)
        guard case .underlying = underlying as? TranscriptionError else {
            XCTFail("real failures must remain TranscriptionError.underlying")
            return
        }
    }

    func testLocaleMatchingFallsBackToLanguageCode() {
        XCTAssertTrue(
            SpeechAnalyzerEngine.localeMatches(
                Locale(identifier: "es-419"),
                in: [Locale(identifier: "es-ES")]
            )
        )
        XCTAssertFalse(
            SpeechAnalyzerEngine.localeMatches(
                Locale(identifier: "en-US"),
                in: [Locale(identifier: "es-ES")]
            )
        )
    }

    private func makeBuffer(format: AVAudioFormat, value: Float) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        buffer.frameLength = 1
        buffer.floatChannelData![0][0] = value
        return buffer
    }
}

private enum TestSpeechError: Error {
    case failed
}

private actor InstalledLocalesStore {
    private var locales: [Locale] = []
    private var reads = 0

    func read() -> [Locale] {
        reads += 1
        return locales
    }

    func readCount() -> Int {
        reads
    }

    func install(_ locale: Locale) {
        locales = [locale]
    }
}
