import Foundation
import AVFoundation

/// Headless verification: feed an audio file through each engine and print what
/// it returns. Run with:  Nuvi --probe /path/to/audio.{caf,wav,m4a}
/// Lets us confirm SpeechAnalyzer, WhisperKit, and Parakeet actually transcribe
/// on this Mac, independent of the GUI, mic, hotkeys, and pasting.
enum Probe {
    /// A probe must not keep the caller blocked while a third-party engine is
    /// unwinding cancellation. The timeout task wins the race and the caller
    /// returns immediately; the operation handle is cancelled on every exit.
    internal static let defaultTimeoutNanoseconds: UInt64 = 30_000_000_000

    /// File probes can produce buffers faster than a model consumes them. Keep
    /// the input queue finite and preserve the oldest buffers when it fills so
    /// the retained audio remains in temporal order.
    internal static let streamBufferCapacity = 8

    internal enum TimeoutOutcome: Equatable, Sendable {
        case completed
        case timedOut
        case cancelled
    }

    internal enum StreamYieldResult: Equatable {
        case enqueued
        case dropped
        case terminated
    }

    /// A factory is kept alongside its diagnostic name so probe coverage cannot
    /// silently drift when a new engine is added. Factories are only invoked by
    /// the production runner; tests can inject spies without loading models.
    internal struct EngineTarget {
        let name: String
        let makeEngine: () -> TranscriptionEngine

        init(name: String, makeEngine: @escaping () -> TranscriptionEngine) {
            self.name = name
            self.makeEngine = makeEngine
        }
    }

    static func run(path: String, localeID: String) async {
        let url = URL(fileURLWithPath: path)
        let locale = Locale(identifier: localeID)
        print("== Nuvi probe ==\nfile: \(path)\nlocale: \(localeID)\n")

        for target in engineTargets() {
            await testWithTimeout(
                target.name,
                engine: target.makeEngine(),
                url: url,
                locale: locale
            )
        }

        print("\n== probe done ==")
    }

    /// The probe intentionally covers every engine installed in this target.
    /// Construction does not prepare or load a model; that only happens inside
    /// `test`, so deterministic tests can replace all factories with spies.
    internal static func engineTargets(
        speechAnalyzerFactory: @escaping () -> TranscriptionEngine = { SpeechAnalyzerEngine() },
        whisperKitFactory: @escaping () -> TranscriptionEngine = { WhisperKitEngine() },
        parakeetFactory: @escaping () -> TranscriptionEngine = { ParakeetEngine() }
    ) -> [EngineTarget] {
        [
            EngineTarget(name: "SpeechAnalyzer", makeEngine: speechAnalyzerFactory),
            EngineTarget(name: "WhisperKit", makeEngine: whisperKitFactory),
            EngineTarget(name: "Parakeet", makeEngine: parakeetFactory)
        ]
    }

    /// Runs an operation against a hard caller-side deadline.
    ///
    /// A structured task group cannot provide a hard deadline here: leaving the
    /// group waits for every child, including an engine that ignores cancellation.
    /// Regular `Task` handles are therefore used as explicitly owned operations;
    /// both handles are cancelled on completion, timeout, caller cancellation,
    /// and deinitialization. No detached task is introduced or left ownerless.
    @discardableResult
    internal static func runWithTimeout(
        timeoutNanoseconds: UInt64 = defaultTimeoutNanoseconds,
        operation: @escaping @Sendable () async -> Void
    ) async -> TimeoutOutcome {
        if Task.isCancelled {
            return .cancelled
        }

        let session = TimeoutSession()

        let operationTask = Task { [weak session] in
            await operation()
            session?.resolve(.completed)
        }
        let timeoutTask = Task { [weak session] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            session?.resolve(.timedOut)
        }
        session.install(operationTask: operationTask, timeoutTask: timeoutTask)
        if Task.isCancelled {
            session.resolve(.cancelled)
        }

        let outcome = await withTaskCancellationHandler {
            await session.wait()
        } onCancel: {
            session.resolve(.cancelled)
        }
        if Task.isCancelled {
            session.resolve(.cancelled)
        }
        return outcome
    }

    @discardableResult
    private static func testWithTimeout(
        _ name: String,
        engine: TranscriptionEngine,
        url: URL,
        locale: Locale,
        timeoutNanoseconds: UInt64 = defaultTimeoutNanoseconds
    ) async -> TimeoutOutcome {
        let outcome = await runWithTimeout(timeoutNanoseconds: timeoutNanoseconds) {
            await test(name, engine: engine, url: url, locale: locale)
        }
        if outcome == .timedOut {
            print("[\(name)] TIMEOUT after \(timeoutNanoseconds / 1_000_000_000)s\n")
        }
        return outcome
    }

    private static func test(
        _ name: String,
        engine: TranscriptionEngine,
        url: URL,
        locale: Locale
    ) async {
        do {
            try Task.checkCancellation()
            print("[\(name)] preparing…")
            try await engine.prepare(locale: locale)
            try Task.checkCancellation()
            print("[\(name)] feeding audio…")

            let stream = try makeStream(url)
            var finalText = ""
            for try await event in engine.transcribe(stream) {
                try Task.checkCancellation()
                switch event {
                case .partial(let text): finalText = text
                case .final(let text) where !text.isEmpty: finalText = text
                case .final: break
                }
            }
            print("[\(name)] RESULT: \"\(finalText)\"\n")
        } catch is CancellationError {
            // Expected when the hard timeout or the caller cancels. This is not
            // an engine failure and must never be reported as ERROR.
        } catch {
            print("[\(name)] ERROR: \(error)\n")
        }
    }

    /// Creates the bounded stream used by the file reader. Exposing the stream
    /// pair as an internal seam lets tests exercise the exact production policy
    /// without opening a real audio file or loading a model.
    internal static func makeBoundedAudioStream(
        capacity: Int = streamBufferCapacity
    ) -> (stream: AsyncStream<AVAudioPCMBuffer>, continuation: AsyncStream<AVAudioPCMBuffer>.Continuation) {
        let boundedCapacity = max(1, capacity)
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(
            bufferingPolicy: .bufferingOldest(boundedCapacity)
        )
        continuation.onTermination = { termination in
            switch termination {
            case .finished:
                NSLog("Nuvi/probe: bounded audio stream finished")
            case .cancelled:
                NSLog("Nuvi/probe: bounded audio stream cancelled")
            @unknown default:
                NSLog("Nuvi/probe: bounded audio stream terminated")
            }
        }
        return (stream, continuation)
    }

    /// Normalizes AsyncStream's result into a small, testable surface and keeps
    /// dropped input distinct from a consumer that has already terminated.
    internal static func yieldProbeBuffer(
        _ buffer: AVAudioPCMBuffer,
        into continuation: AsyncStream<AVAudioPCMBuffer>.Continuation,
        droppedCount: inout Int
    ) -> StreamYieldResult {
        switch continuation.yield(buffer) {
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

    private static func makeStream(_ url: URL) throws -> AsyncStream<AVAudioPCMBuffer> {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let (stream, continuation) = makeBoundedAudioStream()

        let chunk: AVAudioFrameCount = 4096
        var droppedCount = 0
        while file.framePosition < file.length {
            try Task.checkCancellation()
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
            try file.read(into: buffer)
            if buffer.frameLength == 0 { break }

            switch yieldProbeBuffer(buffer, into: continuation, droppedCount: &droppedCount) {
            case .enqueued, .dropped:
                continue
            case .terminated:
                NSLog("Nuvi/probe: audio stream terminated before file input was exhausted")
                return stream
            }
        }
        continuation.finish()
        if droppedCount > 0 {
            NSLog("Nuvi/probe: dropped \(droppedCount) newest file buffers (bounded queue)")
        }
        return stream
    }
}

private final class TimeoutSession: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Probe.TimeoutOutcome?
    private var continuation: CheckedContinuation<Probe.TimeoutOutcome, Never>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func install(
        operationTask: Task<Void, Never>,
        timeoutTask: Task<Void, Never>
    ) {
        var cancelImmediately = false
        lock.lock()
        if outcome == nil {
            self.operationTask = operationTask
            self.timeoutTask = timeoutTask
        } else {
            cancelImmediately = true
        }
        lock.unlock()

        if cancelImmediately {
            operationTask.cancel()
            timeoutTask.cancel()
        }
    }

    func wait() async -> Probe.TimeoutOutcome {
        await withCheckedContinuation { waitContinuation in
            var immediateOutcome: Probe.TimeoutOutcome?
            lock.lock()
            if let outcome {
                immediateOutcome = outcome
            } else {
                continuation = waitContinuation
            }
            lock.unlock()

            if let immediateOutcome {
                waitContinuation.resume(returning: immediateOutcome)
            }
        }
    }

    func resolve(_ outcome: Probe.TimeoutOutcome) {
        var waitContinuation: CheckedContinuation<Probe.TimeoutOutcome, Never>?
        var operationTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?

        lock.lock()
        guard self.outcome == nil else {
            lock.unlock()
            return
        }
        self.outcome = outcome
        waitContinuation = continuation
        continuation = nil
        operationTask = self.operationTask
        self.operationTask = nil
        timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        lock.unlock()

        // Do not await the operation after timeout: that would reintroduce the
        // unbounded wait this session exists to prevent.
        operationTask?.cancel()
        timeoutTask?.cancel()
        waitContinuation?.resume(returning: outcome)
    }

    deinit {
        resolve(.cancelled)
    }
}
