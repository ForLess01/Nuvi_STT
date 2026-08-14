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

    func testReconfigurationPreparesNewEngineWithSameLocale() async throws {
        let audio = FakeAudioCapture()
        let first = FakeEngine(identifier: "first")
        let second = FakeEngine(identifier: "second")
        let controller = DictationController(
            audio: audio,
            engine: first,
            history: HistoryStore(),
            vocabulary: VocabularyStore(),
            modes: ModesStore(),
            textInjector: FakeTextInjector(),
            engineConfigurationID: "speech-analyzer:model-a"
        )

        controller.start()
        await waitUntil { controller.state == .listening }
        controller.cancel()
        await Task.yield()

        controller.reconfigure(engine: second, configurationID: "whisperkit:model-b")
        controller.start()
        await waitUntil { controller.state == .listening }

        XCTAssertEqual(first.preparedLocales.count, 1)
        XCTAssertEqual(second.preparedLocales.count, 1)
        controller.cancel()
    }

    func testReconfigurationDuringSessionAppliesAfterCancellation() async throws {
        let audio = FakeAudioCapture()
        let first = FakeEngine(identifier: "first")
        let second = FakeEngine(identifier: "second")
        let controller = DictationController(
            audio: audio,
            engine: first,
            history: HistoryStore(),
            vocabulary: VocabularyStore(),
            modes: ModesStore(),
            textInjector: FakeTextInjector(),
            engineConfigurationID: "first:model-a"
        )

        controller.start()
        await waitUntil { controller.state == .listening }
        controller.reconfigure(engine: second, configurationID: "second:model-b")
        controller.cancel()
        await Task.yield()
        controller.start()
        await waitUntil { controller.state == .listening }

        XCTAssertEqual(first.preparedLocales.count, 1)
        XCTAssertEqual(second.preparedLocales.count, 1)
        controller.cancel()
    }

    func testReturningToActiveConfigurationClearsPendingEngine() async throws {
        let audio = FakeAudioCapture()
        let first = FakeEngine(identifier: "first")
        let pending = FakeEngine(identifier: "pending")
        let controller = DictationController(
            audio: audio,
            engine: first,
            history: HistoryStore(),
            vocabulary: VocabularyStore(),
            modes: ModesStore(),
            textInjector: FakeTextInjector(),
            engineConfigurationID: "first:model-a"
        )

        controller.start()
        await waitUntil { controller.state == .listening }
        controller.reconfigure(engine: pending, configurationID: "second:model-b")
        controller.reconfigure(engine: first, configurationID: "first:model-a")
        controller.cancel()
        await Task.yield()
        controller.start()
        await waitUntil { controller.state == .listening }

        XCTAssertEqual(first.preparedLocales.count, 1)
        XCTAssertEqual(pending.preparedLocales.count, 0)
        controller.cancel()
    }

    func testImmediateCancelRestartKeepsNewSessionAndDefersReconfiguration() async throws {
        let audio = FakeAudioCapture()
        let first = FakeEngine(identifier: "first")
        let replacement = FakeEngine(identifier: "replacement")
        let controller = DictationController(
            audio: audio,
            engine: first,
            history: HistoryStore(),
            vocabulary: VocabularyStore(),
            modes: ModesStore(),
            textInjector: FakeTextInjector(),
            engineConfigurationID: "first:model-a"
        )

        controller.start()
        await waitUntil { controller.state == .listening }
        controller.cancel()
        controller.start() // Intentionally no yield: session A cleanup may still be running.
        controller.reconfigure(engine: replacement, configurationID: "replacement:model-b")
        await waitUntil { controller.state == .listening }
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(replacement.preparedLocales.count, 0)

        controller.cancel()
        controller.start()
        await waitUntil { controller.state == .listening }
        XCTAssertEqual(replacement.preparedLocales.count, 1)
        controller.cancel()
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
    let identifier: String
    var prepareError: Error?
    var events: [TranscriptionEvent] = []
    var preparedLocales: [String] = []
    private var continuation: AsyncThrowingStream<TranscriptionEvent, Error>.Continuation?

    init(identifier: String = "fake") {
        self.identifier = identifier
    }

    func prepare(locale: Locale) async throws {
        preparedLocales.append(locale.identifier)
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
