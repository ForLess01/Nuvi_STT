import AVFoundation
import XCTest
@testable import Nuvi

final class LiveEngineSupportTests: XCTestCase {
    func testWhisperLiveWindowRemainsBoundedWhileKeepingNewestSamples() {
        var window = RollingAudioWindow(capacity: 4)
        var largestSnapshot = 0

        for chunk in [[Float(1), 2], [3, 4], [5, 6], [7, 8]] {
            window.append(contentsOf: chunk)
            let snapshot = window.snapshot()
            largestSnapshot = max(largestSnapshot, snapshot.count)
            XCTAssertLessThanOrEqual(snapshot.count, window.capacity)
        }

        XCTAssertEqual(largestSnapshot, 4)
        XCTAssertEqual(window.count, 4)
        XCTAssertEqual(window.snapshot(), [5, 6, 7, 8])

        window.append(contentsOf: [9, 10, 11, 12, 13])
        XCTAssertEqual(window.snapshot(), [10, 11, 12, 13])
        XCTAssertEqual(WhisperKitEngine.liveWindowSamples, 480_000)
    }

    func testStandardEngineCancellationAndDomainErrorsStayDistinct() {
        XCTAssertTrue(
            WhisperKitEngine.normalizedTranscriptionError(CancellationError()) is CancellationError
        )
        XCTAssertTrue(
            ParakeetEngine.normalizedTranscriptionError(CancellationError()) is CancellationError
        )

        XCTAssertEqual(
            WhisperKitEngine.normalizedTranscriptionError(NuviError.noAudioReceived) as? NuviError,
            NuviError.noAudioReceived
        )
        XCTAssertEqual(
            ParakeetEngine.normalizedTranscriptionError(NuviError.noAudioReceived) as? NuviError,
            NuviError.noAudioReceived
        )

        let whisperKnown = WhisperKitEngine.normalizedTranscriptionError(
            TranscriptionError.engineUnavailable("not prepared")
        ) as? TranscriptionError
        let parakeetKnown = ParakeetEngine.normalizedTranscriptionError(
            TranscriptionError.engineUnavailable("not prepared")
        ) as? TranscriptionError
        guard case .engineUnavailable("not prepared") = whisperKnown else {
            return XCTFail("WhisperKit must preserve typed transcription errors")
        }
        guard case .engineUnavailable("not prepared") = parakeetKnown else {
            return XCTFail("Parakeet must preserve typed transcription errors")
        }
    }

    func testWhisperLiveCadenceCoversEveryCataloguedModelSize() {
        XCTAssertEqual(
            WhisperKitEngine.liveCadenceSamples(for: "openai_whisper-tiny"),
            24_000
        )
        XCTAssertEqual(
            WhisperKitEngine.liveCadenceSamples(for: "openai_whisper-base"),
            24_000
        )
        XCTAssertEqual(
            WhisperKitEngine.liveCadenceSamples(for: "openai_whisper-small"),
            32_000
        )
        XCTAssertEqual(
            WhisperKitEngine.liveCadenceSamples(for: "openai_whisper-medium"),
            48_000
        )
        XCTAssertEqual(
            WhisperKitEngine.liveCadenceSamples(for: "openai_whisper-large-v3"),
            48_000
        )
    }

    func testHybridForwardsLivePartialRequestToPreparedFallback() async throws {
        let primary = LiveRequestSpy(identifier: "primary", prepareError: ProbeError.unavailable)
        let fallback = LiveRequestSpy(identifier: "fallback")
        let hybrid = HybridTranscriptionEngine(primary: primary, fallback: fallback)
        try await hybrid.prepare(locale: Locale(identifier: "es-419"))

        let (audio, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        continuation.finish()
        for try await _ in hybrid.transcribe(audio, reportingPartials: true) {}

        XCTAssertEqual(fallback.reportingPartialsRequests, [true])
        XCTAssertTrue(primary.reportingPartialsRequests.isEmpty)
    }
}

private enum ProbeError: Error {
    case unavailable
}

private final class LiveRequestSpy: TranscriptionEngine, @unchecked Sendable {
    let identifier: String
    let prepareError: Error?
    var reportingPartialsRequests: [Bool] = []

    init(identifier: String, prepareError: Error? = nil) {
        self.identifier = identifier
        self.prepareError = prepareError
    }

    func prepare(locale: Locale) async throws {
        if let prepareError { throw prepareError }
    }

    func transcribe(
        _ audio: AsyncStream<AVAudioPCMBuffer>
    ) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func transcribe(
        _ audio: AsyncStream<AVAudioPCMBuffer>,
        reportingPartials: Bool
    ) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        reportingPartialsRequests.append(reportingPartials)
        return AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}
