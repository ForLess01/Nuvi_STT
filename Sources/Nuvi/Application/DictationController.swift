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

public struct SystemTextInjector: TextInserting {
    public init() {}

    @MainActor
    public func insert(_ text: String, restoreClipboard: Bool) -> InjectionResult {
        TextInjector.insert(text, restoreClipboard: restoreClipboard)
    }
}

@MainActor
public final class DictationController: ObservableObject {
    @Published public private(set) var state: DictationState = .idle
    @Published public private(set) var level: Float = 0
    @Published public private(set) var transcript: String = ""

    private let audio: AudioCapturing
    private var engine: TranscriptionEngine
    private var engineConfigurationID: String
    private var pendingEngine: (engine: TranscriptionEngine, configurationID: String)?
    private let history: HistoryStore
    private let vocabulary: VocabularyStore
    private let modes: ModesStore
    private let textInjector: TextInserting
    private var session: Task<Void, Never>?
    private var sessionID: UUID?
    private var preparedConfiguration: String?
    private var stopRequested = false

    public init(audio: AudioCapturing,
                engine: TranscriptionEngine,
                history: HistoryStore,
                vocabulary: VocabularyStore,
                modes: ModesStore,
                textInjector: TextInserting = SystemTextInjector(),
                engineConfigurationID: String? = nil) {
        self.audio = audio
        self.engine = engine
        self.engineConfigurationID = engineConfigurationID ?? engine.identifier
        self.history = history
        self.vocabulary = vocabulary
        self.modes = modes
        self.textInjector = textInjector
        self.audio.onLevel = { [weak self] level in
            Task { @MainActor in self?.level = level }
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
        case .idle, .notice, .error: start()
        case .listening: stop()
        case .transcribing: break
        }
    }

    public func start() {
        // Guard on the session itself, not state: during the async start-up gap
        // state is still .idle, so a second trigger could spawn a 2nd session.
        guard session == nil else { return }
        NSLog("Nuvi/session: start requested")
        stopRequested = false
        transcript = ""
        let id = UUID()
        sessionID = id
        session = Task { await runSession(id: id) }
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
        state = .transcribing
        NuviSound.stop()
        audio.stop() // ends the buffer stream → engine emits the final segment
    }

    /// Discard the session entirely (Esc).
    public func cancel() {
        NSLog("Nuvi/session: cancel requested")
        let cancelled = session
        session = nil
        sessionID = nil
        cancelled?.cancel()
        audio.stop()
        NuviSound.cancel()
        clearSessionState()
    }

    // MARK: - Session

    private func runSession(id: UUID) async {
        do {
            guard ownsSession(id) else { return }
            guard await audio.requestPermission() else {
                fail(.micPermissionDenied, ownedBy: id)
                return
            }
            guard ownsSession(id), !Task.isCancelled else { return }

            let locale = SettingsStore.shared.localeIdentifier
            let preparationKey = "\(engineConfigurationID)|\(locale)"
            if preparedConfiguration != preparationKey {
                NSLog("Nuvi/session: preparing engine=\(engine.identifier), locale=\(locale)")
                try await engine.prepare(locale: Locale(identifier: locale))
                guard ownsSession(id), !Task.isCancelled else { return }
                preparedConfiguration = preparationKey
            }

            guard ownsSession(id), !Task.isCancelled else { return }
            let buffers = try audio.start()
            state = .listening
            NSLog("Nuvi/session: listening")
            NuviSound.start()

            // If the user already released PTT during start-up, stop immediately.
            if stopRequested {
                stopRequested = false
                performStop()
            }

            for try await event in engine.transcribe(buffers) {
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

            let result = await deliver()
            finish(result, ownedBy: id)
        } catch is CancellationError {
            reset(ownedBy: id)
        } catch {
            fail(Self.describe(error), ownedBy: id)
        }
    }

    private func deliver() async -> InjectionResult? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Run through the active mode (vocabulary + formatting + affixes). The
        // frontmost app may auto-activate a bound mode.
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let mode = modes.effectiveMode(frontmostBundleID: frontmost)
        let final = mode.transform(trimmed, vocabulary: vocabulary)
        history.add(final)

        NSLog("Nuvi/session: delivering text, characters=\(final.count)")
        let result = textInjector.insert(final, restoreClipboard: SettingsStore.shared.restoreClipboard)
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
        case .some(.clipboardOnly(let reason)):
            notice(.clipboardFallback(reason), ownedBy: id)
        case .some(.manualFallback(let reason)):
            notice(.manualOutputRequired(reason), ownedBy: id)
        case .some(.inserted):
            reset(ownedBy: id)
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
        state = .idle
        level = 0
        transcript = ""
        session = nil
        sessionID = nil
        stopRequested = false
        applyPendingEngineIfNeeded()
    }

    /// Non-fatal feedback (clipboard fallback, nothing said). Frees the session so
    /// the user can immediately try again, and always leaves a coded log trail.
    private func notice(_ error: NuviError, ownedBy id: UUID) {
        guard ownsSession(id) else { return }
        NSLog("Nuvi/notice [\(error.code)]: \(error.message)")
        state = .notice(error.display)
        level = 0
        transcript = ""
        session = nil
        sessionID = nil
        stopRequested = false
        applyPendingEngineIfNeeded()
    }

    private func fail(_ error: NuviError, ownedBy id: UUID) {
        guard ownsSession(id) else { return }
        NSLog("Nuvi/error [\(error.code)]: \(error.message)")
        audio.stop()
        NuviSound.error()
        state = .error(error.display)
        level = 0
        transcript = ""
        session = nil
        sessionID = nil
        stopRequested = false
        applyPendingEngineIfNeeded()
    }

    /// Map any thrown error to a coded `NuviError`. Already-coded errors pass
    /// through untouched, so engine-level codes survive to the UI and the log.
    private static func describe(_ error: Error) -> NuviError {
        if let coded = error as? NuviError { return coded }
        if case AudioCaptureError.microphoneInUse = error { return .micInUse }
        if case let AudioCaptureError.microphoneUnavailable(reason) = error { return .micUnavailable(reason) }
        if case let TranscriptionError.unsupportedLocale(id) = error { return .unsupportedLocale(id) }
        if case TranscriptionError.assetUnavailable = error { return .assetUnavailable }
        if case let TranscriptionError.engineUnavailable(reason) = error { return .engineUnavailable(reason) }
        if case let TranscriptionError.underlying(reason) = error { return .engineFailed(reason) }
        return .unexpected(String(describing: error))
    }
}
