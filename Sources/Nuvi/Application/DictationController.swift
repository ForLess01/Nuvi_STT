import Foundation
import AVFoundation
import AppKit
import Combine

/// Use-case orchestrator. Wires microphone → transcription engine → text
/// injection, and publishes the state/level/transcript the UI observes.
///
/// It depends only on abstractions (`AudioCaptureService`, `TranscriptionEngine`),
/// so it can be unit-tested with fakes. It knows nothing about pills or Metal.
public protocol TextInserting: Sendable {
    @MainActor
    func insert(_ text: String, restoreClipboard: Bool) -> InjectionResult
}

@MainActor
public protocol LiveTextInserting: AnyObject {
    /// Captures the currently focused, non-secure editable target.
    func begin() -> Bool
    /// Reconciles the previous provisional text with the latest hypothesis.
    func update(_ text: String) -> Bool
    /// Replaces the provisional hypothesis with the settled output.
    func finish(_ text: String, restoreClipboard: Bool) -> InjectionResult
    /// Removes provisional text when the session is cancelled or fails.
    func cancel()
}

public struct SystemTextInjector: TextInserting {
    public init() {}

    @MainActor
    public func insert(_ text: String, restoreClipboard: Bool) -> InjectionResult {
        TextInjector.insert(text, restoreClipboard: restoreClipboard)
    }
}

public protocol TextTranslating {
    @MainActor
    func translate(_ text: String, to target: TranslationTarget) async throws -> String
}

public struct PassthroughTextTranslator: TextTranslating {
    public init() {}

    @MainActor
    public func translate(_ text: String, to target: TranslationTarget) async throws -> String {
        text
    }
}

/// Turns engine-specific LIVE hypotheses into one monotonic document.
///
/// Streaming engines do not share one result contract: some revise the whole
/// transcript, while others finalize one utterance at a silence boundary and
/// restart the next hypothesis from an empty string. Keeping committed and
/// provisional text separate prevents a restarted hypothesis from deleting
/// everything that was already inserted into the target editor.
struct LiveTranscriptAssembler: Equatable {
    private(set) var committed = ""
    private(set) var provisional = ""

    var text: String { Self.join(committed, provisional) }

    mutating func consume(_ event: TranscriptionEvent) -> String? {
        let before = text
        switch event {
        case .partial(let value):
            consumePartial(Self.cleaned(value))
        case .final(let value):
            consumeFinal(Self.cleaned(value))
        }

        let after = text
        return after != before ? after : nil
    }

    private mutating func consumePartial(_ incoming: String) {
        // Empty/whitespace hypotheses are common during silence and flushes.
        // They are not an instruction to erase the current LIVE document.
        guard !incoming.isEmpty else { return }

        if !committed.isEmpty,
           let remainder = Self.remainder(of: incoming, after: committed) {
            // Cumulative engine: it repeated the protected prefix and revised
            // only the tail. An empty tail is a temporary contraction, not a
            // command to delete the current provisional text.
            guard !remainder.isEmpty else { return }
            reconcilePartial(with: remainder)
        } else {
            reconcilePartial(with: incoming)
        }
    }

    private mutating func consumeFinal(_ incoming: String) {
        guard !incoming.isEmpty else { return }

        if committed.isEmpty {
            // A final result is authoritative for the current utterance, even
            // when it corrects the first word and shares no literal prefix with
            // the last volatile hypothesis.
            committed = incoming
            provisional = ""
            return
        }

        if let remainder = Self.remainder(of: incoming, after: committed) {
            // Some engines publish the complete document as their final event.
            // Preserve an already inserted tail when an empty final arrives
            // after silence instead of visibly rolling the editor backwards.
            guard !remainder.isEmpty else { return }
            committed = Self.join(committed, remainder)
            provisional = ""
            return
        }

        if !provisional.isEmpty {
            if Self.isAggregateRevision(text, incoming) {
                // Full-session final pass (Whisper/Parakeet): replace the
                // assembled hypotheses with the authoritative aggregate.
                committed = incoming
            } else {
                // Segment final (SpeechAnalyzer): replace only its volatile
                // hypothesis, then protect the segment across the next pause.
                committed = Self.join(committed, incoming)
            }
            provisional = ""
            return
        }

        // A settled segment may arrive without any preceding volatile result.
        committed = Self.join(committed, incoming)
    }

    private mutating func reconcilePartial(with incoming: String) {
        guard !provisional.isEmpty else {
            provisional = incoming
            return
        }
        guard provisional != incoming else { return }

        if Self.isRevision(provisional, incoming) {
            // Volatile partials sometimes briefly contract to an older prefix
            // during silence. Do not let a non-final contraction delete text.
            if provisional.hasPrefix(incoming), incoming.count < provisional.count {
                return
            }
            provisional = incoming
            return
        }

        // A disjoint hypothesis means the engine restarted at an utterance
        // boundary. Protect the prior segment instead of replacing it.
        committed = Self.join(committed, provisional)
        provisional = incoming
    }

    private static func isRevision(_ previous: String, _ incoming: String) -> Bool {
        if previous.hasPrefix(incoming) || incoming.hasPrefix(previous) { return true }

        let lhs = Array(previous.lowercased())
        let rhs = Array(incoming.lowercased())
        let limit = min(lhs.count, rhs.count)
        guard limit > 0 else { return false }
        var common = 0
        while common < limit, lhs[common] == rhs[common] { common += 1 }
        let required = max(3, min(12, limit / 3))
        return common >= required
    }

    private static func isAggregateRevision(_ previous: String, _ incoming: String) -> Bool {
        if isRevision(previous, incoming) { return true }

        let lhs = normalizedWords(previous)
        let rhs = normalizedWords(incoming)
        let limit = min(lhs.count, rhs.count)
        guard limit >= 3 else { return false }

        // Full-session decoders often add punctuation near the beginning, so
        // their literal character prefix can be short even though the settled
        // result clearly revises the same document.
        var commonPrefix = 0
        while commonPrefix < limit, lhs[commonPrefix] == rhs[commonPrefix] {
            commonPrefix += 1
        }
        return commonPrefix >= 3 && rhs.count * 2 >= lhs.count
    }

    private static func remainder(of aggregate: String, after prefix: String) -> String? {
        guard aggregate.hasPrefix(prefix) else { return nil }
        return cleaned(String(aggregate.dropFirst(prefix.count)))
    }

    static func join(_ left: String, _ right: String) -> String {
        let left = cleaned(left)
        let right = cleaned(right)
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }
        if left == right || left.hasSuffix(right) { return left }
        if right.hasPrefix(left) { return right }

        let leftWords = left.split(whereSeparator: \.isWhitespace).map(String.init)
        let rightWords = right.split(whereSeparator: \.isWhitespace).map(String.init)
        let overlapLimit = min(leftWords.count, rightWords.count)
        var overlap = 0
        if overlapLimit > 0 {
            for size in stride(from: overlapLimit, through: 1, by: -1) {
                let lhs = leftWords.suffix(size).map(normalizedWord)
                let rhs = rightWords.prefix(size).map(normalizedWord)
                if lhs == rhs {
                    overlap = size
                    break
                }
            }
        }
        if overlap > 0 {
            return (leftWords + rightWords.dropFirst(overlap)).joined(separator: " ")
        }

        let punctuation = CharacterSet(charactersIn: ",.!?;:)]}")
        if let first = right.unicodeScalars.first, punctuation.contains(first) {
            return left + right
        }
        return left + " " + right
    }

    private static func normalizedWord(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    private static func normalizedWords(_ value: String) -> [String] {
        value.split(whereSeparator: \.isWhitespace)
            .map { normalizedWord(String($0)) }
            .filter { !$0.isEmpty }
    }

    private static func cleaned(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
protocol CompletionFeedbackScheduling: AnyObject {
    func schedule(
        after delay: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    ) -> AnyCancellable
}

@MainActor
private final class LiveCompletionFeedbackScheduler: CompletionFeedbackScheduling {
    func schedule(
        after delay: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    ) -> AnyCancellable {
        let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
        let task = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            action()
        }
        return AnyCancellable { task.cancel() }
    }
}

@MainActor
public final class DictationController: ObservableObject {
    private enum CompletionFeedback {
        static let duration: TimeInterval = 0.9
    }

    @Published public private(set) var state: DictationState = .idle
    @Published public private(set) var level: Float = 0
    @Published public private(set) var spectrum: AudioSpectrum = .zero
    @Published public private(set) var transcript: String = ""
    @Published public private(set) var isLiveSession = false

    private let audio: AudioCapturing
    private var engine: TranscriptionEngine
    private var engineConfigurationID: String
    private var pendingEngine: (engine: TranscriptionEngine, configurationID: String)?
    private let history: HistoryStore
    private let vocabulary: VocabularyStore
    private let modes: ModesStore
    private let textInjector: TextInserting
    private let liveTextInjector: LiveTextInserting
    private let textTranslator: TextTranslating
    private let translationTarget: () -> TranslationTarget
    private let deliveryMode: () -> DictationDeliveryMode
    private let silenceDetectionEnabled: () -> Bool
    private let silenceDurationThreshold: () -> TimeInterval
    private let duckAudioDuringDictation: () -> Bool
    private let completionScheduler: CompletionFeedbackScheduling
    private var session: Task<Void, Never>?
    private var sessionID: UUID?
    private var preparedConfiguration: String?
    private var stopRequested = false
    private var completionCancellation: AnyCancellable?
    private var completionToken: UUID?
    private var liveInsertionStarted = false
    private var hasSpokenInCurrentSession = false
    private var silenceStopTask: Task<Void, Never>?

    public convenience init(audio: AudioCapturing,
                            engine: TranscriptionEngine,
                            history: HistoryStore,
                            vocabulary: VocabularyStore,
                            modes: ModesStore,
                            textInjector: TextInserting = SystemTextInjector(),
                            liveTextInjector: LiveTextInserting? = nil,
                            textTranslator: TextTranslating = PassthroughTextTranslator(),
                            translationTarget: @escaping () -> TranslationTarget = {
                                SettingsStore.shared.translationTarget
                            },
                            deliveryMode: @escaping () -> DictationDeliveryMode = {
                                SettingsStore.shared.dictationDeliveryMode
                            },
                            silenceDetectionEnabled: @escaping () -> Bool = {
                                SettingsStore.shared.silenceDetectionEnabled
                            },
                            silenceDurationThreshold: @escaping () -> TimeInterval = {
                                SettingsStore.shared.silenceDurationThreshold
                            },
                            duckAudioDuringDictation: @escaping () -> Bool = {
                                SettingsStore.shared.duckAudioDuringDictation
                            },
                            engineConfigurationID: String? = nil) {
        self.init(
            audio: audio,
            engine: engine,
            history: history,
            vocabulary: vocabulary,
            modes: modes,
            textInjector: textInjector,
            liveTextInjector: liveTextInjector,
            textTranslator: textTranslator,
            translationTarget: translationTarget,
            deliveryMode: deliveryMode,
            silenceDetectionEnabled: silenceDetectionEnabled,
            silenceDurationThreshold: silenceDurationThreshold,
            duckAudioDuringDictation: duckAudioDuringDictation,
            engineConfigurationID: engineConfigurationID,
            completionScheduler: LiveCompletionFeedbackScheduler()
        )
    }

    init(audio: AudioCapturing,
         engine: TranscriptionEngine,
         history: HistoryStore,
         vocabulary: VocabularyStore,
         modes: ModesStore,
         textInjector: TextInserting,
         liveTextInjector: LiveTextInserting? = nil,
         textTranslator: TextTranslating = PassthroughTextTranslator(),
         translationTarget: @escaping () -> TranslationTarget = {
             SettingsStore.shared.translationTarget
         },
         deliveryMode: @escaping () -> DictationDeliveryMode = {
             SettingsStore.shared.dictationDeliveryMode
         },
         silenceDetectionEnabled: @escaping () -> Bool = {
             SettingsStore.shared.silenceDetectionEnabled
         },
         silenceDurationThreshold: @escaping () -> TimeInterval = {
             SettingsStore.shared.silenceDurationThreshold
         },
         duckAudioDuringDictation: @escaping () -> Bool = {
             SettingsStore.shared.duckAudioDuringDictation
         },
         engineConfigurationID: String?,
         completionScheduler: CompletionFeedbackScheduling) {
        self.audio = audio
        self.engine = engine
        self.engineConfigurationID = engineConfigurationID ?? engine.identifier
        self.history = history
        self.vocabulary = vocabulary
        self.modes = modes
        self.textInjector = textInjector
        self.liveTextInjector = liveTextInjector ?? SystemLiveTextInjector()
        self.textTranslator = textTranslator
        self.translationTarget = translationTarget
        self.deliveryMode = deliveryMode
        self.silenceDetectionEnabled = silenceDetectionEnabled
        self.silenceDurationThreshold = silenceDurationThreshold
        self.duckAudioDuringDictation = duckAudioDuringDictation
        self.completionScheduler = completionScheduler
        self.audio.onLevel = { [weak self] level in
            Task { @MainActor in
                guard let self else { return }
                self.level = level
                self.processSilenceDetection(level: level)
            }
        }
        self.audio.onSpectrum = { [weak self] spectrum in
            Task { @MainActor in
                guard let self else { return }
                self.spectrum = spectrum
                self.level = spectrum.level
                self.processSilenceDetection(level: spectrum.level)
            }
        }
    }

    /// Applies an engine/model change immediately when idle, or safely defers it
    /// until the active recording finishes. The next session prepares the new
    /// adapter even when the locale did not change.
    public func reconfigure(engine: TranscriptionEngine, configurationID: String) {
        if session != nil {
            if configurationID == engineConfigurationID {
                // The user returned to the active configuration before the
                // recording ended; discard any previously queued replacement.
                pendingEngine = nil
            } else if pendingEngine?.configurationID != configurationID {
                pendingEngine = (engine, configurationID)
            }
        } else if configurationID != engineConfigurationID {
            apply(engine: engine, configurationID: configurationID)
        }
    }

    private func apply(engine: TranscriptionEngine, configurationID: String) {
        self.engine = engine
        engineConfigurationID = configurationID
        preparedConfiguration = nil
    }

    private func applyPendingEngineIfNeeded() {
        guard let pendingEngine else { return }
        self.pendingEngine = nil
        apply(engine: pendingEngine.engine, configurationID: pendingEngine.configurationID)
    }

    /// Hotkey / menu entry point: start when idle, stop when listening.
    public func toggle() {
        switch state {
        case .idle, .inserted, .copied, .notice, .error: start()
        case .listening: stop()
        case .transcribing: break
        }
    }

    public func start() {
        // Guard on the session itself, not state: during the async start-up gap
        // state is still .idle, so a second trigger could spawn a 2nd session.
        guard session == nil else { return }
        cancelCompletionFeedback()
        cancelSilenceTimer()
        hasSpokenInCurrentSession = false
        NSLog("Nuvi/session: start requested")
        stopRequested = false
        transcript = ""
        isLiveSession = false
        // Capture this synchronously before any permission, model preparation,
        // or other suspension point. A setting change during startup belongs to
        // the next dictation, never to this one.
        let captureConfiguration = AudioCaptureConfiguration(
            duckOtherAudio: duckAudioDuringDictation()
        )

        let isLive = deliveryMode() == .live
        if isLive {
            guard liveTextInjector.begin() else {
                let error = NuviError.liveTargetUnavailable(
                    tr(
                        "Focus an editable text field before starting Live",
                        "Enfoca un campo de texto editable antes de iniciar Live"
                    )
                )
                NSLog("Nuvi/notice [\(error.code)]: \(error.message)")
                state = .notice(error.display)
                level = 0
                spectrum = .zero
                return
            }
            liveInsertionStarted = true
            isLiveSession = true
            NSLog("Nuvi/live: editable target captured, engine=\(engine.identifier)")
        }

        let id = UUID()
        sessionID = id
        session = Task {
            await runSession(
                id: id,
                isLive: isLive,
                captureConfiguration: captureConfiguration
            )
        }
    }

    /// User finished speaking (or released push-to-talk).
    public func stop() {
        if state == .listening {
            performStop()
        } else if session != nil {
            // Released before the mic was live (PTT tap). Stop as soon as it is.
            stopRequested = true
        }
    }

    private func performStop() {
        guard state == .listening else { return }
        NSLog("Nuvi/session: stop requested")
        cancelSilenceTimer()
        state = .transcribing
        NuviSound.stop()
        audio.stop() // ends the buffer stream → engine emits the final segment
    }

    /// Discard the session entirely (Esc).
    public func cancel() {
        NSLog("Nuvi/session: cancel requested")
        cancelSilenceTimer()
        let cancelled = session
        session = nil
        sessionID = nil
        cancelled?.cancel()
        audio.stop()
        cancelLiveInsertion()
        NuviSound.cancel()
        clearSessionState()
    }

    private func processSilenceDetection(level: Float) {
        guard state == .listening, silenceDetectionEnabled() else { return }

        let speechThreshold: Float = 0.10
        let silenceThreshold: Float = 0.07

        if level >= speechThreshold {
            hasSpokenInCurrentSession = true
            cancelSilenceTimer()
            return
        }

        if hasSpokenInCurrentSession {
            if level > silenceThreshold {
                // Intermediate sound (whisper, soft syllable) - cancel pending countdown
                cancelSilenceTimer()
            } else if silenceStopTask == nil {
                // Sustained silence (< 0.07) - start countdown to auto-stop
                let duration = max(0.5, silenceDurationThreshold())
                let nanos = UInt64(duration * 1_000_000_000)
                silenceStopTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: nanos)
                    guard !Task.isCancelled, let self, self.state == .listening else { return }
                    NSLog("Nuvi/session: auto-stopping due to detected silence")
                    self.stop()
                }
            }
        }
    }

    private func cancelSilenceTimer() {
        silenceStopTask?.cancel()
        silenceStopTask = nil
    }

    // MARK: - Session

    private func runSession(
        id: UUID,
        isLive: Bool,
        captureConfiguration: AudioCaptureConfiguration
    ) async {
        do {
            guard ownsSession(id) else { return }
            guard await audio.requestPermission() else {
                fail(.micPermissionDenied, ownedBy: id)
                return
            }
            guard ownsSession(id), !Task.isCancelled else {
                reset(ownedBy: id)
                return
            }

            let locale = SettingsStore.shared.localeIdentifier
            let preparationKey = "\(engineConfigurationID)|\(locale)"
            if preparedConfiguration != preparationKey {
                NSLog("Nuvi/session: preparing engine=\(engine.identifier), locale=\(locale)")
                try await engine.prepare(locale: Locale(identifier: locale))
                guard ownsSession(id), !Task.isCancelled else {
                    reset(ownedBy: id)
                    return
                }
                preparedConfiguration = preparationKey
            }

            guard ownsSession(id), !Task.isCancelled else {
                reset(ownedBy: id)
                return
            }
            let buffers = try audio.start(configuration: captureConfiguration)
            state = .listening
            NSLog("Nuvi/session: listening")
            NuviSound.start()

            // If the user already released PTT during start-up, stop immediately.
            if stopRequested {
                stopRequested = false
                performStop()
            }

            var liveTranscript = LiveTranscriptAssembler()
            for try await event in engine.transcribe(buffers, reportingPartials: isLive) {
                hasSpokenInCurrentSession = true
                cancelSilenceTimer()
                if isLive {
                    guard let assembled = liveTranscript.consume(event) else { continue }
                    transcript = assembled
                    try updateLiveInsertion(with: assembled)
                    continue
                }
                switch event {
                case .partial(let text):
                    transcript = text
                case .final(let text) where !text.isEmpty:
                    transcript = text
                case .final:
                    break
                }
            }

            guard ownsSession(id), !Task.isCancelled else {
                reset(ownedBy: id)
                return
            }

            let result = try await deliver()
            finish(result, ownedBy: id)
        } catch is CancellationError {
            reset(ownedBy: id)
        } catch {
            fail(Self.describe(error), ownedBy: id)
        }
    }

    private func deliver() async throws -> InjectionResult? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Run through the active mode (vocabulary + formatting + affixes). The
        // frontmost app may auto-activate a bound mode.
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let mode = modes.effectiveMode(frontmostBundleID: frontmost)
        let transformed = mode.transform(trimmed, vocabulary: vocabulary)
        let output = try await textTranslator.translate(transformed, to: translationTarget())
        history.add(output)

        NSLog("Nuvi/session: delivering text, characters=\(output.count)")
        let restoreClipboard = SettingsStore.shared.restoreClipboard
        let result: InjectionResult
        if liveInsertionStarted {
            result = liveTextInjector.finish(output, restoreClipboard: restoreClipboard)
            liveInsertionStarted = false
        } else {
            result = textInjector.insert(output, restoreClipboard: restoreClipboard)
        }
        switch result {
        case .inserted:
            NuviSound.pasted()
        case .clipboardOnly(let reason):
            NuviSound.copied()
            NSLog("Nuvi: \(reason)")
        case .manualFallback(let reason):
            NuviSound.error()
            NSLog("Nuvi: \(reason)")
        }
        return result
    }

    private func finish(_ result: InjectionResult?, ownedBy id: UUID) {
        guard ownsSession(id) else { return }
        switch result {
        case .some(.clipboardOnly):
            complete(as: .copied, ownedBy: id)
        case .some(.manualFallback(let reason)):
            notice(.manualOutputRequired(reason), ownedBy: id)
        case .some(.inserted):
            complete(as: .inserted, ownedBy: id)
        case .none:
            // Listened but produced nothing — surface it instead of failing silently.
            notice(.noSpeechDetected, ownedBy: id)
        }
    }

    private func ownsSession(_ id: UUID) -> Bool {
        sessionID == id
    }

    private func reset(ownedBy id: UUID) {
        guard ownsSession(id) else { return }
        clearSessionState()
    }

    private func clearSessionState() {
        cancelSilenceTimer()
        hasSpokenInCurrentSession = false
        cancelLiveInsertion()
        cancelCompletionFeedback()
        state = .idle
        level = 0
        spectrum = .zero
        transcript = ""
        session = nil
        sessionID = nil
        stopRequested = false
        isLiveSession = false
        applyPendingEngineIfNeeded()
    }

    private func complete(as completionState: DictationState, ownedBy id: UUID) {
        guard ownsSession(id) else { return }
        cancelCompletionFeedback()
        state = completionState
        level = 0
        spectrum = .zero
        transcript = ""
        session = nil
        sessionID = nil
        stopRequested = false
        liveInsertionStarted = false
        isLiveSession = false
        applyPendingEngineIfNeeded()

        let token = UUID()
        completionToken = token
        completionCancellation = completionScheduler.schedule(
            after: CompletionFeedback.duration
        ) { [weak self] in
            guard let self,
                  self.completionToken == token,
                  self.session == nil,
                  self.state == completionState else { return }
            self.completionCancellation = nil
            self.completionToken = nil
            self.state = .idle
        }
    }

    private func cancelCompletionFeedback() {
        completionCancellation?.cancel()
        completionCancellation = nil
        completionToken = nil
    }

    /// Non-fatal feedback (clipboard fallback, nothing said). Frees the session so
    /// the user can immediately try again, and always leaves a coded log trail.
    private func notice(_ error: NuviError, ownedBy id: UUID) {
        guard ownsSession(id) else { return }
        cancelCompletionFeedback()
        cancelLiveInsertion()
        NSLog("Nuvi/notice [\(error.code)]: \(error.message)")
        state = .notice(error.display)
        level = 0
        spectrum = .zero
        transcript = ""
        session = nil
        sessionID = nil
        stopRequested = false
        isLiveSession = false
        applyPendingEngineIfNeeded()
    }

    private func fail(_ error: NuviError, ownedBy id: UUID) {
        guard ownsSession(id) else { return }
        cancelCompletionFeedback()
        cancelLiveInsertion()
        NSLog("Nuvi/error [\(error.code)]: \(error.message)")
        audio.stop()
        NuviSound.error()
        state = .error(error.display)
        level = 0
        spectrum = .zero
        transcript = ""
        session = nil
        sessionID = nil
        stopRequested = false
        isLiveSession = false
        applyPendingEngineIfNeeded()
    }

    private func updateLiveInsertion(with text: String) throws {
        guard liveInsertionStarted, !text.isEmpty else { return }
        if !liveTextInjector.update(text) {
            // Live is target-bound by design. Continuing after focus changes
            // could insert the next revision into the wrong field, so stop the
            // session instead of silently degrading to standard delivery.
            NSLog("Nuvi/live: editable target lost; stopping live session")
            liveTextInjector.cancel()
            liveInsertionStarted = false
            throw NuviError.liveTargetUnavailable(
                tr(
                    "Live stopped because the editable text field changed",
                    "Live se detuvo porque cambió el campo de texto editable"
                )
            )
        }
    }

    private func cancelLiveInsertion() {
        guard liveInsertionStarted else { return }
        liveTextInjector.cancel()
        liveInsertionStarted = false
    }

    /// Map any thrown error to a coded `NuviError`. Already-coded errors pass
    /// through untouched, so engine-level codes survive to the UI and the log.
    private static func describe(_ error: Error) -> NuviError {
        if let coded = error as? NuviError { return coded }
        if case AudioCaptureError.microphoneInUse = error { return .micInUse }
        if case let AudioCaptureError.microphoneUnavailable(reason) = error { return .micUnavailable(reason) }
        if case let AudioCaptureError.nativeDuckingUnavailable(reason) = error {
            let englishGuidance = "Audio Ducking is unavailable. Disable Audio Ducking or select a supported microphone."
            let detail = reason.hasPrefix(englishGuidance)
                ? String(reason.dropFirst(englishGuidance.count)).trimmingCharacters(in: .whitespaces)
                : reason
            let guidance = tr(
                "Audio Ducking is unavailable. Disable Audio Ducking or select a supported microphone.",
                "La atenuación de audio no está disponible. Desactivá Audio Ducking o seleccioná un micrófono compatible."
            )
            return .nativeDuckingUnavailable(
                detail.isEmpty ? guidance : "\(guidance) \(detail)"
            )
        }
        if case let TranscriptionError.unsupportedLocale(id) = error { return .unsupportedLocale(id) }
        if case TranscriptionError.assetUnavailable = error { return .assetUnavailable }
        if case let TranscriptionError.engineUnavailable(reason) = error { return .engineUnavailable(reason) }
        if case let TranscriptionError.underlying(reason) = error { return .engineFailed(reason) }
        return .unexpected(String(describing: error))
    }
}
