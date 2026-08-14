import XCTest
import AVFoundation
import Combine
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

    func testManualFallbackBecomesCodedControllerNotice() async throws {
        let audio = FakeAudioCapture()
        let engine = FakeEngine()
        engine.events = [.final("hello")]
        let reason = "Focused target could not be classified"
        let injector = FakeTextInjector(result: .manualFallback(reason))
        let controller = DictationController(
            audio: audio,
            engine: engine,
            history: HistoryStore(),
            vocabulary: VocabularyStore(),
            modes: ModesStore(),
            textInjector: injector
        )

        controller.start()
        await waitUntil { controller.state == .notice(NuviError.manualOutputRequired(reason).display) }

        XCTAssertEqual(controller.state, .notice(NuviError.manualOutputRequired(reason).display))
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

    func testInsertedStateTransitionsToIdleWhenCompletionFeedbackExpires() async {
        let audio = FakeAudioCapture()
        let engine = FakeEngine()
        engine.events = [.final("completed text")]
        let scheduler = ManualCompletionFeedbackScheduler()
        let controller = DictationController(
            audio: audio,
            engine: engine,
            history: HistoryStore(isHistoryEnabled: { true }),
            vocabulary: VocabularyStore(),
            modes: ModesStore(),
            textInjector: FakeTextInjector(),
            engineConfigurationID: nil,
            completionScheduler: scheduler
        )

        controller.start()
        await yieldUntil { controller.state == .inserted }

        XCTAssertEqual(controller.state, .inserted)
        XCTAssertEqual(scheduler.scheduledDelays, [0.9])
        scheduler.firePending()
        XCTAssertEqual(controller.state, .idle)
    }

    func testTranslatedOutputIsInsertedAndStoredAsTheRecentTranscription() async {
        let audio = FakeAudioCapture()
        let engine = FakeEngine()
        engine.events = [.final("texto original")]
        let history = HistoryStore(isHistoryEnabled: { true })
        let injector = FakeTextInjector()
        let translator = FakeTextTranslator(output: "translated output")
        let controller = DictationController(
            audio: audio,
            engine: engine,
            history: history,
            vocabulary: VocabularyStore(),
            modes: ModesStore(),
            textInjector: injector,
            textTranslator: translator,
            translationTarget: { .englishUK }
        )

        controller.start()
        await yieldUntil { controller.state == .inserted }

        XCTAssertEqual(translator.requests, [.init(text: "texto original", target: .englishUK)])
        XCTAssertEqual(injector.insertedTexts, ["translated output"])
        XCTAssertEqual(history.entries.map(\.text), ["translated output"])
    }

    func testClipboardDeliveryShowsCopiedCompletionState() async {
        let audio = FakeAudioCapture()
        let engine = FakeEngine()
        engine.events = [.final("copy me")]
        let scheduler = ManualCompletionFeedbackScheduler()
        let controller = DictationController(
            audio: audio,
            engine: engine,
            history: HistoryStore(isHistoryEnabled: { true }),
            vocabulary: VocabularyStore(),
            modes: ModesStore(),
            textInjector: FakeTextInjector(result: .clipboardOnly("Copied to clipboard")),
            engineConfigurationID: nil,
            completionScheduler: scheduler
        )

        controller.start()
        await yieldUntil { controller.state == .copied }

        XCTAssertEqual(controller.state, .copied)
        XCTAssertEqual(scheduler.scheduledDelays, [0.9])
        scheduler.firePending()
        XCTAssertEqual(controller.state, .idle)
    }

    func testTranslationFailureDoesNotInsertOrPersistTheOriginalText() async {
        let audio = FakeAudioCapture()
        let engine = FakeEngine()
        engine.events = [.final("private original")]
        let history = HistoryStore(isHistoryEnabled: { true })
        let injector = FakeTextInjector()
        let failure = NuviError.translationFailed("language model unavailable")
        let controller = DictationController(
            audio: audio,
            engine: engine,
            history: history,
            vocabulary: VocabularyStore(),
            modes: ModesStore(),
            textInjector: injector,
            textTranslator: FailingTextTranslator(error: failure),
            translationTarget: { .portugueseBrazil }
        )

        controller.start()
        await yieldUntil { controller.state == .error(failure.display) }

        XCTAssertEqual(controller.state, .error(failure.display))
        XCTAssertTrue(injector.insertedTexts.isEmpty)
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testLiveModeStreamsPartialRevisionsAndCommitsFinalTextWithoutDuplicateInsertion() async {
        let audio = FakeAudioCapture()
        let engine = FakeEngine()
        engine.events = [.partial("Hello"), .partial("Hello wor"), .final("Hello world")]
        let standardInjector = FakeTextInjector()
        let liveInjector = FakeLiveTextInjector()
        let controller = DictationController(
            audio: audio,
            engine: engine,
            history: HistoryStore(isHistoryEnabled: { true }),
            vocabulary: VocabularyStore(),
            modes: ModesStore(),
            textInjector: standardInjector,
            liveTextInjector: liveInjector,
            deliveryMode: { .live }
        )

        controller.start()
        await yieldUntil { controller.state == .inserted }

        XCTAssertEqual(liveInjector.updates, ["Hello", "Hello wor", "Hello world"])
        XCTAssertEqual(liveInjector.finishedTexts, ["Hello world"])
        XCTAssertTrue(standardInjector.insertedTexts.isEmpty)
        XCTAssertEqual(engine.reportingPartialsRequests, [true])
    }

    func testLiveModePreservesCommittedTextWhenEngineRestartsAfterPause() async {
        let audio = FakeAudioCapture()
        let engine = FakeEngine()
        engine.events = [
            .partial("Primera frase"),
            .final("Primera frase."),
            .partial("Segunda frase"),
            .partial("Segunda frase continúa"),
            .final("Segunda frase continúa.")
        ]
        let liveInjector = FakeLiveTextInjector()
        let controller = DictationController(
            audio: audio,
            engine: engine,
            history: HistoryStore(),
            vocabulary: VocabularyStore(),
            modes: ModesStore(),
            textInjector: FakeTextInjector(),
            liveTextInjector: liveInjector,
            deliveryMode: { .live }
        )

        controller.start()
        await yieldUntil { controller.state == .inserted }

        XCTAssertEqual(
            liveInjector.updates,
            [
                "Primera frase",
                "Primera frase.",
                "Primera frase. Segunda frase",
                "Primera frase. Segunda frase continúa",
                "Primera frase. Segunda frase continúa."
            ]
        )
        XCTAssertEqual(
            liveInjector.finishedTexts,
            ["Primera frase. Segunda frase continúa."]
        )
    }

    func testLiveAssemblerIgnoresSilenceAndProtectsDisjointPartialRestart() {
        var assembler = LiveTranscriptAssembler()

        XCTAssertEqual(assembler.consume(.partial("Keep this text")), "Keep this text")
        XCTAssertNil(assembler.consume(.partial("   ")))
        XCTAssertEqual(
            assembler.consume(.partial("new phrase after pause")),
            "Keep this text new phrase after pause"
        )
        XCTAssertEqual(
            assembler.consume(.partial("new phrase after pause continues")),
            "Keep this text new phrase after pause continues"
        )
    }

    func testLiveAssemblerDoesNotDeleteOnTemporaryPartialContraction() {
        var assembler = LiveTranscriptAssembler()

        XCTAssertEqual(assembler.consume(.partial("A complete provisional phrase")), "A complete provisional phrase")
        XCTAssertNil(assembler.consume(.partial("A complete")))
        XCTAssertEqual(assembler.text, "A complete provisional phrase")
        XCTAssertEqual(
            assembler.consume(.final("A complete corrected phrase")),
            "A complete corrected phrase"
        )
    }

    func testLiveAssemblerMergesOverlappingRestartWithoutRepeatingBoundaryWords() {
        var assembler = LiveTranscriptAssembler()

        XCTAssertEqual(assembler.consume(.partial("one two three")), "one two three")
        XCTAssertEqual(assembler.consume(.partial("three four five")), "one two three four five")
    }

    func testLiveAssemblerAcceptsCumulativeResultsAfterACommittedSegment() {
        var assembler = LiveTranscriptAssembler()

        XCTAssertEqual(assembler.consume(.final("First sentence.")), "First sentence.")
        XCTAssertEqual(
            assembler.consume(.partial("First sentence. Second sentence")),
            "First sentence. Second sentence"
        )
    }

    func testLiveAssemblerUsesDisjointFinalAsAuthoritativeCorrection() {
        var assembler = LiveTranscriptAssembler()

        XCTAssertEqual(assembler.consume(.partial("beach")), "beach")
        XCTAssertEqual(assembler.consume(.final("peach")), "peach")
        XCTAssertEqual(assembler.text, "peach")
    }

    func testLiveAssemblerReplacesAssembledPartialsWithFullSessionFinal() {
        var assembler = LiveTranscriptAssembler()

        XCTAssertEqual(assembler.consume(.partial("First phrase")), "First phrase")
        XCTAssertEqual(
            assembler.consume(.partial("Second phrase after pause")),
            "First phrase Second phrase after pause"
        )
        XCTAssertEqual(
            assembler.consume(.final("First phrase. Second phrase after pause.")),
            "First phrase. Second phrase after pause."
        )
    }

    func testLiveAssemblerRecognizesPunctuatedParakeetFinalAfterAProvisionalRestart() {
        var assembler = LiveTranscriptAssembler()

        XCTAssertEqual(
            assembler.consume(.partial("And so my fellow Americans ask not")),
            "And so my fellow Americans ask not"
        )
        XCTAssertEqual(
            assembler.consume(.partial("what your country can do for you")),
            "And so my fellow Americans ask not what your country can do for you"
        )
        XCTAssertEqual(
            assembler.consume(.final(
                "And so, my fellow Americans, ask not what your country can do for you."
            )),
            "And so, my fellow Americans, ask not what your country can do for you."
        )
    }

    func testLiveAssemblerDoesNotEraseTailWhenCumulativePartialContractsToCommittedPrefix() {
        var assembler = LiveTranscriptAssembler()

        XCTAssertEqual(assembler.consume(.final("First sentence.")), "First sentence.")
        XCTAssertEqual(
            assembler.consume(.partial("First sentence. Second sentence")),
            "First sentence. Second sentence"
        )
        XCTAssertNil(assembler.consume(.partial("First sentence.")))
        XCTAssertEqual(assembler.text, "First sentence. Second sentence")
    }

    func testLiveModeReplacesProvisionalSourceWithTranslatedFinalOutput() async {
        let audio = FakeAudioCapture()
        let engine = FakeEngine()
        engine.events = [.partial("prueba"), .final("prueba automática")]
        let liveInjector = FakeLiveTextInjector()
        let controller = DictationController(
            audio: audio,
            engine: engine,
            history: HistoryStore(isHistoryEnabled: { true }),
            vocabulary: VocabularyStore(),
            modes: ModesStore(),
            textInjector: FakeTextInjector(),
            liveTextInjector: liveInjector,
            textTranslator: FakeTextTranslator(output: "automatic test"),
            translationTarget: { .englishUS },
            deliveryMode: { .live }
        )

        controller.start()
        await yieldUntil { controller.state == .inserted }

        XCTAssertEqual(liveInjector.updates, ["prueba", "prueba automática"])
        XCTAssertEqual(liveInjector.finishedTexts, ["automatic test"])
    }

    func testCancellingLiveModeRemovesItsProvisionalText() async {
        let audio = FakeAudioCapture()
        let engine = FakeEngine()
        let liveInjector = FakeLiveTextInjector()
        let controller = DictationController(
            audio: audio,
            engine: engine,
            history: HistoryStore(),
            vocabulary: VocabularyStore(),
            modes: ModesStore(),
            textInjector: FakeTextInjector(),
            liveTextInjector: liveInjector,
            deliveryMode: { .live }
        )

        controller.start()
        await waitUntil { controller.state == .listening }
        XCTAssertTrue(controller.isLiveSession)
        engine.emit(.partial("temporary words"))
        await waitUntil { controller.transcript == "temporary words" }
        controller.cancel()

        XCTAssertEqual(liveInjector.cancelCount, 1)
        XCTAssertFalse(controller.isLiveSession)
    }

    func testLiveModeDoesNotStartWithoutAnEditableTarget() async {
        let audio = FakeAudioCapture()
        let engine = FakeEngine()
        let liveInjector = FakeLiveTextInjector(beginResult: false)
        let controller = DictationController(
            audio: audio,
            engine: engine,
            history: HistoryStore(),
            vocabulary: VocabularyStore(),
            modes: ModesStore(),
            textInjector: FakeTextInjector(),
            liveTextInjector: liveInjector,
            deliveryMode: { .live }
        )

        controller.start()
        await Task.yield()

        guard case .notice(let message) = controller.state else {
            return XCTFail("Expected a notice when Live has no editable target")
        }
        XCTAssertTrue(message.contains("NUVI-O03"))
        XCTAssertEqual(liveInjector.beginCount, 1)
        XCTAssertEqual(audio.permissionRequestCount, 0)
        XCTAssertEqual(audio.startCount, 0)
        XCTAssertTrue(engine.preparedLocales.isEmpty)
        XCTAssertFalse(controller.isLiveSession)
    }

    func testLiveTargetLossStopsInsteadOfFallingBackToAnotherField() async {
        let audio = FakeAudioCapture()
        let engine = FakeEngine()
        engine.events = [.partial("Hello"), .final("Hello world")]
        let standardInjector = FakeTextInjector()
        let liveInjector = FakeLiveTextInjector(updateResult: false)
        let controller = DictationController(
            audio: audio,
            engine: engine,
            history: HistoryStore(),
            vocabulary: VocabularyStore(),
            modes: ModesStore(),
            textInjector: standardInjector,
            liveTextInjector: liveInjector,
            deliveryMode: { .live }
        )

        controller.start()
        await yieldUntil {
            if case .error(let message) = controller.state {
                return message.contains("NUVI-O03")
            }
            return false
        }

        XCTAssertEqual(liveInjector.cancelCount, 1)
        XCTAssertTrue(standardInjector.insertedTexts.isEmpty)
        XCTAssertTrue(liveInjector.finishedTexts.isEmpty)
        XCTAssertFalse(controller.isLiveSession)
    }

    func testStartingNewDictationCancelsOldCompletionFeedback() async {
        let audio = FakeAudioCapture()
        let engine = FakeEngine()
        engine.events = [.final("completed text")]
        let scheduler = ManualCompletionFeedbackScheduler()
        let controller = DictationController(
            audio: audio,
            engine: engine,
            history: HistoryStore(isHistoryEnabled: { true }),
            vocabulary: VocabularyStore(),
            modes: ModesStore(),
            textInjector: FakeTextInjector(),
            engineConfigurationID: nil,
            completionScheduler: scheduler
        )

        controller.start()
        await yieldUntil { controller.state == .inserted }

        engine.events = []
        controller.start()
        await yieldUntil { controller.state == .listening }
        scheduler.fireAllIncludingCancelled()

        XCTAssertTrue(scheduler.allScheduledWorkWasCancelled)
        XCTAssertEqual(controller.state, .listening)
        controller.cancel()
    }

    func testStaleCompletionCallbackCannotHideNewNoticeOrError() async {
        let audio = FakeAudioCapture()
        let engine = FakeEngine()
        engine.events = [.final("completed text")]
        let scheduler = ManualCompletionFeedbackScheduler()
        let controller = DictationController(
            audio: audio,
            engine: engine,
            history: HistoryStore(isHistoryEnabled: { true }),
            vocabulary: VocabularyStore(),
            modes: ModesStore(),
            textInjector: FakeTextInjector(),
            engineConfigurationID: nil,
            completionScheduler: scheduler
        )

        controller.start()
        await yieldUntil { controller.state == .inserted }

        engine.events = [.final("")]
        controller.start()
        await yieldUntil { controller.state == .notice(NuviError.noSpeechDetected.display) }
        scheduler.fireAllIncludingCancelled()
        XCTAssertEqual(controller.state, .notice(NuviError.noSpeechDetected.display))

        audio.startError = AudioCaptureError.microphoneInUse
        controller.start()
        await yieldUntil { controller.state == .error(NuviError.micInUse.display) }
        scheduler.fireAllIncludingCancelled()
        XCTAssertEqual(controller.state, .error(NuviError.micInUse.display))
    }

    private func yieldUntil(_ predicate: @escaping @MainActor () -> Bool) async {
        for _ in 0..<1_000 where !predicate() {
            await Task.yield()
        }
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
    private(set) var permissionRequestCount = 0
    private(set) var startCount = 0
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    func requestPermission() async -> Bool {
        permissionRequestCount += 1
        return permission
    }

    func start() throws -> AsyncStream<AVAudioPCMBuffer> {
        startCount += 1
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
    var reportingPartialsRequests: [Bool] = []
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

    func transcribe(
        _ audio: AsyncStream<AVAudioPCMBuffer>,
        reportingPartials: Bool
    ) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        reportingPartialsRequests.append(reportingPartials)
        return transcribe(audio)
    }

    func emit(_ event: TranscriptionEvent) {
        continuation?.yield(event)
    }
}

@MainActor
private final class FakeTextInjector: TextInserting {
    private(set) var insertedTexts: [String] = []
    private let result: InjectionResult

    init(result: InjectionResult = .inserted) {
        self.result = result
    }

    func insert(_ text: String, restoreClipboard: Bool) -> InjectionResult {
        insertedTexts.append(text)
        return result
    }
}

@MainActor
private final class FakeLiveTextInjector: LiveTextInserting {
    private(set) var updates: [String] = []
    private(set) var finishedTexts: [String] = []
    private(set) var cancelCount = 0
    private(set) var beginCount = 0
    private let beginResult: Bool
    private let updateResult: Bool

    init(beginResult: Bool = true, updateResult: Bool = true) {
        self.beginResult = beginResult
        self.updateResult = updateResult
    }

    func begin() -> Bool {
        beginCount += 1
        return beginResult
    }

    func update(_ text: String) -> Bool {
        updates.append(text)
        return updateResult
    }

    func finish(_ text: String, restoreClipboard: Bool) -> InjectionResult {
        finishedTexts.append(text)
        return .inserted
    }

    func cancel() {
        cancelCount += 1
    }
}

@MainActor
private final class FakeTextTranslator: TextTranslating {
    struct Request: Equatable {
        let text: String
        let target: TranslationTarget
    }

    private let output: String
    private(set) var requests: [Request] = []

    init(output: String) {
        self.output = output
    }

    func translate(_ text: String, to target: TranslationTarget) async throws -> String {
        requests.append(Request(text: text, target: target))
        return output
    }
}

@MainActor
private final class FailingTextTranslator: TextTranslating {
    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func translate(_ text: String, to target: TranslationTarget) async throws -> String {
        throw error
    }
}

@MainActor
private final class ManualCompletionFeedbackScheduler: CompletionFeedbackScheduling {
    private final class ScheduledWork {
        let action: @MainActor @Sendable () -> Void
        var isCancelled = false

        init(action: @escaping @MainActor @Sendable () -> Void) {
            self.action = action
        }
    }

    private var work: [ScheduledWork] = []
    private(set) var scheduledDelays: [TimeInterval] = []

    var allScheduledWorkWasCancelled: Bool {
        !work.isEmpty && work.allSatisfy(\.isCancelled)
    }

    func schedule(
        after delay: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    ) -> AnyCancellable {
        let scheduled = ScheduledWork(action: action)
        scheduledDelays.append(delay)
        work.append(scheduled)
        return AnyCancellable { scheduled.isCancelled = true }
    }

    func firePending() {
        work.filter { !$0.isCancelled }.forEach { $0.action() }
    }

    func fireAllIncludingCancelled() {
        work.forEach { $0.action() }
    }
}
