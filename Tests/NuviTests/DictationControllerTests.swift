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

    func testStartSnapshotsAudioDuckingBeforePermissionAwaits() async {
        let audio = FakeAudioCapture()
        audio.holdPermission = true
        let engine = FakeEngine()
        var requestedDucking = true
        let controller = DictationController(
            audio: audio,
            engine: engine,
            history: HistoryStore(),
            vocabulary: VocabularyStore(),
            modes: ModesStore(),
            textInjector: FakeTextInjector(),
            duckAudioDuringDictation: { requestedDucking }
        )

        controller.start()
        await waitUntil { audio.permissionRequestCount == 1 }
        requestedDucking = false
        audio.releasePermission()
        await waitUntil { controller.state == .listening }

        XCTAssertEqual(audio.configurations, [AudioCaptureConfiguration(duckOtherAudio: true)])
        controller.cancel()
    }

    func testAudioCaptureConvenienceStartDefaultsToNonDuckingConfiguration() throws {
        let audio = FakeAudioCapture()
        _ = try audio.start()

        XCTAssertEqual(audio.configurations, [AudioCaptureConfiguration(duckOtherAudio: false)])
        audio.stop()
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

    func testSilenceDetectionAutoStopsSessionAfterSpeechFollowedBySilence() async {
        let audio = FakeAudioCapture()
        let engine = FakeEngine()
        engine.events = []
        let controller = DictationController(
            audio: audio,
            engine: engine,
            history: HistoryStore(),
            vocabulary: VocabularyStore(),
            modes: ModesStore(),
            textInjector: FakeTextInjector(),
            silenceDetectionEnabled: { true },
            silenceDurationThreshold: { 0.1 }
        )

        controller.start()
        await yieldUntil { controller.state == .listening }

        // Speech starts
        audio.onLevel?(0.25)
        await Task.yield()

        // Silence follows
        audio.onLevel?(0.01)

        // Wait for auto-stop to trigger performStop()
        await waitUntil { audio.stopCount == 1 && controller.state == .transcribing }

        XCTAssertEqual(audio.stopCount, 1)
        XCTAssertEqual(controller.state, .transcribing)

        // Deliver final text from engine to finish
        engine.emit(.final("dictated text"))
        engine.finish()

        await waitUntil { controller.state == .inserted }
        XCTAssertEqual(controller.state, .inserted)
    }

    func testSlowNativeStartAllowsCancelAndQueuesReplacementAfterTeardown() async {
        let audio = FakeAudioCapture()
        let gate = NativeControlGate()
        audio.startGate = gate
        let controller = DictationController(
            audio: audio, engine: FakeEngine(), history: HistoryStore(),
            vocabulary: VocabularyStore(), modes: ModesStore(), textInjector: FakeTextInjector()
        )
        defer { gate.open(); controller.cancel() }
        controller.start()
        await fulfillment(of: [gate.entered], timeout: 3)
        XCTAssertFalse(gate.ranOnMain, "Native start must leave the main actor responsive")
        XCTAssertFalse(gate.timedOut, "The user action must run before native startup returns")
        controller.cancel()
        controller.start()
        XCTAssertEqual(audio.startCount, 1, "Replacement must wait for old native teardown")
        XCTAssertNotEqual(controller.state, .listening, "Cancelled startup cannot publish listening")
        gate.open()
        await waitUntil { audio.startCount == 2 && controller.state == .listening }
        XCTAssertEqual(Array(audio.controlEvents.prefix(3)), ["start", "stop", "start"])
    }

    func testReleaseDuringSlowNativeStartupFinalizesOnce() async {
        let audio = FakeAudioCapture()
        let gate = NativeControlGate()
        audio.startGate = gate
        let engine = FakeEngine()
        let injector = FakeTextInjector()
        let controller = DictationController(
            audio: audio, engine: engine, history: HistoryStore(),
            vocabulary: VocabularyStore(), modes: ModesStore(), textInjector: injector
        )
        defer { gate.open(); controller.cancel() }
        controller.start()
        await fulfillment(of: [gate.entered], timeout: 3)
        XCTAssertFalse(gate.timedOut)
        controller.stop()
        gate.open()
        await waitUntil { audio.stopCount == 1 && controller.state == .transcribing }
        engine.emit(.final("released during startup"))
        engine.finish()
        await waitUntil { controller.state == .inserted }
        XCTAssertEqual(injector.insertedTexts, ["released during startup"])
        XCTAssertEqual(audio.stopCount, 1)
    }

    func testSlowNativeStopAllowsCancelWithoutStartingReplacementEarly() async {
        let audio = FakeAudioCapture()
        let engine = FakeEngine()
        let controller = DictationController(
            audio: audio, engine: engine, history: HistoryStore(),
            vocabulary: VocabularyStore(), modes: ModesStore(), textInjector: FakeTextInjector()
        )
        controller.start()
        await waitUntil { controller.state == .listening }
        let gate = NativeControlGate()
        audio.stopGate = gate
        defer { gate.open(); controller.cancel() }
        controller.stop()
        await fulfillment(of: [gate.entered], timeout: 3)
        XCTAssertFalse(gate.ranOnMain)
        XCTAssertFalse(gate.timedOut)
        controller.cancel()
        controller.start()
        XCTAssertEqual(audio.startCount, 1)
        gate.open()
        await waitUntil { audio.startCount == 2 && controller.state == .listening }
        XCTAssertEqual(Array(audio.controlEvents.prefix(3)), ["start", "stop", "start"])
    }

    func testOldCaptureFeedbackCannotArmSilenceOrChangeReplacementSpectrum() async {
        let audio = FakeAudioCapture()
        let engine = FakeEngine()
        let injector = FakeTextInjector()
        let controller = DictationController(
            audio: audio, engine: engine, history: HistoryStore(),
            vocabulary: VocabularyStore(), modes: ModesStore(), textInjector: injector,
            silenceDetectionEnabled: { true }, silenceDurationThreshold: { 0.1 }
        )
        defer { controller.cancel() }
        controller.start()
        await waitUntil { controller.state == .listening }
        let oldLevel = audio.capturedLevels[0]
        let oldSpectrum = audio.capturedSpectra[0]
        oldLevel?(0.8)
        await waitUntil { controller.level == 0.8 }
        XCTAssertEqual(controller.level, 0.8, "A's speech callback must have been processed")
        oldLevel?(0)
        await waitUntil { self.hasArmedSilenceTimer(controller) }
        XCTAssertEqual(controller.level, 0)
        XCTAssertTrue(hasArmedSilenceTimer(controller), "Observe A's actual timer before cancellation")
        // The timer clamps this fixture's threshold to 0.5s. Only after its
        // handle exists do we establish a deadline beyond its possible firing.
        let pastOldDeadline = ContinuousClock.now.advanced(by: .milliseconds(650))
        controller.cancel()
        controller.start()
        await waitUntil { audio.startCount == 2 && controller.state == .listening }
        XCTAssertFalse(hasArmedSilenceTimer(controller), "B starts without A's timer")
        oldSpectrum?(AudioSpectrum(level: 0.8, bass: 1, mid: 1, treble: 1))
        oldLevel?(0)
        // Cancellation already terminates A's iterator: prove that these
        // attempted late events are dropped, not that its error handler runs.
        switch engine.oldContinuations[0].yield(.final("stale capture text")) {
        case .terminated: break
        default: XCTFail("Canceled capture iterator must reject late events")
        }
        engine.oldContinuations[0].finish(throwing: FakeError.prepareFailed)
        try? await Task.sleep(until: pastOldDeadline, clock: .continuous)
        XCTAssertEqual(controller.state, .listening)
        XCTAssertFalse(hasArmedSilenceTimer(controller))
        XCTAssertEqual(controller.spectrum, .zero)
        XCTAssertEqual(controller.level, 0)
        XCTAssertEqual(controller.transcript, "")
        XCTAssertEqual(audio.stopCount, 1)

        controller.stop()
        await waitUntil { audio.stopCount == 2 && controller.state == .transcribing }
        engine.emit(.final("replacement capture text"))
        engine.finish()
        await waitUntil { controller.state == .inserted }
        XCTAssertEqual(injector.insertedTexts, ["replacement capture text"])
        XCTAssertEqual(audio.stopCount, 2)
    }

    private func hasArmedSilenceTimer(_ controller: DictationController) -> Bool {
        // Read the existing private handle without adding production test API.
        guard let timer = Mirror(reflecting: controller).children.first(where: {
            $0.label == "silenceStopTask"
        })?.value else { return false }
        return !Mirror(reflecting: timer).children.isEmpty
    }

    func testCanceledStartupErrorCannotFailReplacementSession() async {
        let audio = FakeAudioCapture()
        let gate = NativeControlGate()
        audio.startGate = gate
        audio.startError = AudioCaptureError.microphoneInUse
        let controller = DictationController(
            audio: audio, engine: FakeEngine(), history: HistoryStore(),
            vocabulary: VocabularyStore(), modes: ModesStore(), textInjector: FakeTextInjector()
        )
        defer { gate.open(); controller.cancel() }
        controller.start()
        await fulfillment(of: [gate.entered], timeout: 3)
        controller.cancel()
        audio.startError = nil
        controller.start()
        gate.open()
        await waitUntil { audio.startCount == 2 && controller.state == .listening }
        XCTAssertEqual(controller.state, .listening)
    }

    func testCanceledTranslationCannotDeliverIntoReplacementSession() async {
        let audio = FakeAudioCapture()
        let engine = FakeEngine()
        let translator = SuspendedTextTranslator()
        let history = HistoryStore(isHistoryEnabled: { true })
        let injector = FakeTextInjector()
        let controller = DictationController(
            audio: audio, engine: engine, history: history,
            vocabulary: VocabularyStore(), modes: ModesStore(), textInjector: injector,
            textTranslator: translator, translationTarget: { .portugueseBrazil }
        )
        defer { translator.resume(); controller.cancel() }
        controller.start()
        await waitUntil { controller.state == .listening }
        engine.emit(.final("old capture"))
        engine.finish()
        await fulfillment(of: [translator.entered], timeout: 1)
        controller.cancel()
        controller.start()
        await waitUntil { audio.startCount == 2 && controller.state == .listening }
        translator.resume()
        await fulfillment(of: [translator.returned], timeout: 1)
        await Task.yield()
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(controller.transcript, "")
        XCTAssertTrue(injector.insertedTexts.isEmpty)
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testRepeatedPTTCyclesPreserveDuckingAndFinalizeOncePerSession() async {
        let audio = FakeAudioCapture()
        let engine = FakeEngine()
        let injector = FakeTextInjector()
        var ducking = true
        let controller = DictationController(
            audio: audio, engine: engine, history: HistoryStore(),
            vocabulary: VocabularyStore(), modes: ModesStore(), textInjector: injector,
            duckAudioDuringDictation: { ducking }
        )
        defer { controller.cancel() }
        for index in 0..<3 {
            ducking = index != 1
            controller.start()
            await waitUntil { controller.state == .listening }
            controller.stop()
            await waitUntil { audio.stopCount == index + 1 }
            engine.emit(.final("cycle \(index)"))
            engine.finish()
            await waitUntil { controller.state == .inserted }
        }
        XCTAssertEqual(audio.configurations.map(\.duckOtherAudio), [true, false, true])
        XCTAssertEqual(injector.insertedTexts, ["cycle 0", "cycle 1", "cycle 2"])
        XCTAssertEqual(audio.stopCount, 3)
    }

    func testPreviewCancelDuringNativeStartSharesSerialOwnershipBoundary() async {
        let audio = FakeAudioCapture()
        let gate = NativeControlGate()
        audio.startGate = gate
        let preview = FerrofluidMicProbe(capture: audio)
        defer { gate.open(); preview.stop() }
        preview.start()
        await fulfillment(of: [gate.entered], timeout: 3)
        XCTAssertFalse(gate.ranOnMain)
        XCTAssertFalse(gate.timedOut)
        preview.toggle()
        preview.start()
        XCTAssertEqual(audio.startCount, 1)
        gate.open()
        await waitUntil { audio.startCount == 2 && preview.active }
        audio.capturedSpectra[0]?(AudioSpectrum(level: 1, bass: 1, mid: 1, treble: 1))
        await Task.yield()
        XCTAssertEqual(preview.spectrum, .zero)
        XCTAssertEqual(Array(audio.controlEvents.prefix(3)), ["start", "stop", "start"])
        XCTAssertTrue(audio.configurations.allSatisfy { !$0.duckOtherAudio })
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
    private let lock = NSLock()
    var onLevel: (@Sendable (Float) -> Void)?
    var onSpectrum: (@Sendable (AudioSpectrum) -> Void)?
    var permission = true
    private var _startError: Error? = nil
    var startError: Error? {
        get { lock.withLock { _startError } }
        set { lock.withLock { _startError = newValue } }
    }
    var holdPermission = false
    private var _permissionRequestCount: Int = 0
    var permissionRequestCount: Int {
        get { lock.withLock { _permissionRequestCount } }
    }
    private var _startGate: NativeControlGate? = nil
    var startGate: NativeControlGate? {
        get { lock.withLock { _startGate } }
        set { lock.withLock { _startGate = newValue } }
    }
    private var _stopGate: NativeControlGate? = nil
    var stopGate: NativeControlGate? {
        get { lock.withLock { _stopGate } }
        set { lock.withLock { _stopGate = newValue } }
    }
    private var _controlEvents: [String] = []
    var controlEvents: [String] {
        get { lock.withLock { _controlEvents } }
    }
    private var _capturedLevels: [(@Sendable (Float) -> Void)?] = []
    var capturedLevels: [(@Sendable (Float) -> Void)?] {
        get { lock.withLock { _capturedLevels } }
    }
    private var _capturedSpectra: [(@Sendable (AudioSpectrum) -> Void)?] = []
    var capturedSpectra: [(@Sendable (AudioSpectrum) -> Void)?] {
        get { lock.withLock { _capturedSpectra } }
    }
    private var _startCount: Int = 0
    var startCount: Int {
        get { lock.withLock { _startCount } }
    }
    private var _configurations: [AudioCaptureConfiguration] = []
    var configurations: [AudioCaptureConfiguration] {
        get { lock.withLock { _configurations } }
    }
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var permissionContinuation: CheckedContinuation<Bool, Never>?

    func requestPermission() async -> Bool {
        lock.withLock { _permissionRequestCount += 1 }
        if holdPermission {
            return await withCheckedContinuation { continuation in
                permissionContinuation = continuation
            }
        }
        return permission
    }

    func releasePermission() {
        holdPermission = false
        permissionContinuation?.resume(returning: permission)
        permissionContinuation = nil
    }

    func start(configuration: AudioCaptureConfiguration) throws -> AsyncStream<AVAudioPCMBuffer> {
        let (capturedError, gate) = lock.withLock {
            _startCount += 1
            _controlEvents.append("start")
            _configurations.append(configuration)
            _capturedLevels.append(onLevel)
            _capturedSpectra.append(onSpectrum)
            return (_startError, _startGate)
        }
        gate?.block()
        if let capturedError { throw capturedError }
        let pair = AsyncStream<AVAudioPCMBuffer>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }

    private var _stopCount: Int = 0
    var stopCount: Int {
        get { lock.withLock { _stopCount } }
    }

    func stop() {
        let gate = lock.withLock {
            _stopCount += 1
            _controlEvents.append("stop")
            return _stopGate
        }
        gate?.block()
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
    private(set) var oldContinuations: [AsyncThrowingStream<TranscriptionEvent, Error>.Continuation] = []
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
            oldContinuations.append(continuation)
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

    func finish() {
        continuation?.finish()
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
private final class SuspendedTextTranslator: TextTranslating {
    let entered = XCTestExpectation(description: "translation suspended")
    let returned = XCTestExpectation(description: "translation returned")
    private var continuation: CheckedContinuation<String, Never>?

    func translate(_ text: String, to target: TranslationTarget) async throws -> String {
        let result = await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered.fulfill()
        }
        returned.fulfill()
        return result
    }

    func resume() {
        continuation?.resume(returning: "late translation")
        continuation = nil
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

private final class NativeControlGate: @unchecked Sendable {
    let entered = XCTestExpectation(description: "native operation entered")
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var opened = false
    private var onMain = false
    private var timeout = false

    var ranOnMain: Bool {
        lock.lock()
        defer { lock.unlock() }
        return onMain
    }

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timeout
    }

    func block() {
        lock.lock()
        guard !opened else {
            lock.unlock()
            return
        }
        onMain = Thread.isMainThread
        lock.unlock()
        entered.fulfill()
        let result = release.wait(timeout: .now() + 2)
        lock.lock()
        timeout = result == .timedOut
        opened = true
        lock.unlock()
    }

    func open() {
        lock.lock()
        opened = true
        lock.unlock()
        release.signal()
    }
}
