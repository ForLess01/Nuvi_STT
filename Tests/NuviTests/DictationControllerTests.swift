import XCTest
import AVFoundation
@testable import Nuvi

@MainActor
final class DictationControllerTests: XCTestCase {
    func testCanRetryAfterPrepareError() async throws {
        let audio = FakeAudioCapture()
        let engine = FakeEngine()
        engine.prepareError = FakeError.prepareFailed
        let controller = DictationController(audio: audio,
                                            engine: engine,
                                            history: HistoryStore(),
                                            vocabulary: VocabularyStore(),
                                            modes: ModesStore(),
                                            textInjector: FakeTextInjector())

        controller.start()
        await waitUntil { if case .error = controller.state { return true }; return false }

        engine.prepareError = nil
        controller.start()
        await waitUntil { controller.state == .listening }

        XCTAssertEqual(controller.state, .listening)
        controller.cancel()
    }


    func testMicrophoneInUseShowsSpecificError() async throws {
        let audio = FakeAudioCapture()
        audio.startError = AudioCaptureError.microphoneInUse
        let engine = FakeEngine()
        let controller = DictationController(audio: audio,
                                            engine: engine,
                                            history: HistoryStore(),
                                            vocabulary: VocabularyStore(),
                                            modes: ModesStore(),
                                            textInjector: FakeTextInjector())

        controller.start()
        await waitUntil { controller.state == .error(NuviError.micInUse.display) }

        // The surfaced message carries the stable code so failures are never silent
        // and are reportable: "Microphone is being used by another app (NUVI-A02)".
        XCTAssertEqual(controller.state, .error(NuviError.micInUse.display))
        XCTAssertTrue(NuviError.micInUse.display.contains("NUVI-A02"))
    }

    func testEmptyTranscriptShowsCodedNoticeInsteadOfSilence() async throws {
        let audio = FakeAudioCapture()
        let engine = FakeEngine()
        engine.events = [.final("")] // listened, but nothing was said
        let controller = DictationController(audio: audio,
                                            engine: engine,
                                            history: HistoryStore(),
                                            vocabulary: VocabularyStore(),
                                            modes: ModesStore(),
                                            textInjector: FakeTextInjector())

        controller.start()
        await waitUntil { controller.state == .notice(NuviError.noSpeechDetected.display) }

        // Previously this path reset to .idle silently. Now it must surface a code.
        XCTAssertEqual(controller.state, .notice(NuviError.noSpeechDetected.display))
        XCTAssertTrue(NuviError.noSpeechDetected.display.contains("NUVI-T05"))
    }

    func testCancelDoesNotDeliverLateText() async throws {        let audio = FakeAudioCapture()
        let engine = FakeEngine()
        let injector = FakeTextInjector()
        let controller = DictationController(audio: audio,
                                            engine: engine,
                                            history: HistoryStore(),
                                            vocabulary: VocabularyStore(),
                                            modes: ModesStore(),
                                            textInjector: injector)

        controller.start()
        await waitUntil { controller.state == .listening }
        controller.cancel()
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(injector.insertedTexts, [])
    }

    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 where !predicate() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private enum FakeError: Error {
    case prepareFailed
}

private final class FakeAudioCapture: AudioCapturing, @unchecked Sendable {
    var onLevel: (@Sendable (Float) -> Void)?
    var permission = true
    var startError: Error?
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    func requestPermission() async -> Bool { permission }

    func start() throws -> AsyncStream<AVAudioPCMBuffer> {
        if let startError { throw startError }
        let pair = AsyncStream<AVAudioPCMBuffer>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }

    func stop() {
        continuation?.finish()
        continuation = nil
    }
}

private final class FakeEngine: TranscriptionEngine, @unchecked Sendable {
    let identifier = "fake"
    var prepareError: Error?
    var events: [TranscriptionEvent] = []
    private var continuation: AsyncThrowingStream<TranscriptionEvent, Error>.Continuation?

    func prepare(locale: Locale) async throws {
        if let prepareError { throw prepareError }
    }

    func transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
            for event in events {
                continuation.yield(event)
            }
            if !events.isEmpty {
                continuation.finish()
            }
        }
    }
}

@MainActor
private final class FakeTextInjector: TextInserting {
    private(set) var insertedTexts: [String] = []

    func insert(_ text: String, restoreClipboard: Bool) -> InjectionResult {
        insertedTexts.append(text)
        return .inserted
    }
}
