import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import Darwin
import Synchronization

/// Port for microphone capture. Keeping the controller on this abstraction lets
/// tests drive dictation without touching real hardware.
public struct AudioCaptureConfiguration: Equatable, Sendable {
    public let duckOtherAudio: Bool

    public init(duckOtherAudio: Bool = false) {
        self.duckOtherAudio = duckOtherAudio
    }
}

public enum AudioCaptureError: Error, Sendable, Equatable {
    case microphoneInUse
    case microphoneUnavailable(String)
    case nativeDuckingUnavailable(String)
}

public protocol AudioCapturing: AnyObject, Sendable {
    var onLevel: (@Sendable (Float) -> Void)? { get set }
    var onSpectrum: (@Sendable (AudioSpectrum) -> Void)? { get set }
    func requestPermission() async -> Bool
    func start(configuration: AudioCaptureConfiguration) throws -> AsyncStream<AVAudioPCMBuffer>
    func stop()
}

public extension AudioCapturing {
    /// Preview and other source-compatible callers stay explicitly on the
    /// non-ducking HAL path unless they opt into a configuration.
    func start() throws -> AsyncStream<AVAudioPCMBuffer> {
        try start(configuration: AudioCaptureConfiguration())
    }

    var onSpectrum: (@Sendable (AudioSpectrum) -> Void)? {
        get { nil }
        set {}
    }
}

/// Native callback owner that retains its session until admission has closed
/// and every callback that could have read the target has left. The owner stays
/// alive through native disposal, including quarantined teardown failures.
internal final class AudioCaptureCallbackRouter: @unchecked Sendable {
    private static let closedBit: UInt64 = 1 << 63
    private static let callbackCountMask: UInt64 = closedBit - 1
    private let callbackState = Atomic<UInt64>(closedBit)
    private let sessionPointer = Atomic<UInt>(0)

    deinit {
        deactivate()
    }

    func activate(_ session: AudioCaptureSession) -> Bool {
        guard sessionPointer.load(ordering: .acquiring) == 0 else { return false }
        let pointer = UInt(bitPattern: Unmanaged.passRetained(session).toOpaque())
        sessionPointer.store(pointer, ordering: .releasing)
        callbackState.store(0, ordering: .releasing)
        return true
    }

    func deactivate() {
        closeAdmission()
        waitForCallbacks()
        let pointer = sessionPointer.exchange(0, ordering: .acquiringAndReleasing)
        guard pointer != 0, let raw = UnsafeMutableRawPointer(bitPattern: pointer) else { return }
        Unmanaged<AudioCaptureSession>.fromOpaque(raw).release()
    }

    func render(
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        busNumber: UInt32,
        frames: UInt32
    ) -> OSStatus {
        guard enterCallback() else { return noErr }
        defer { leaveCallback() }
        let pointer = sessionPointer.load(ordering: .acquiring)
        guard pointer != 0, let raw = UnsafeMutableRawPointer(bitPattern: pointer) else { return noErr }
        let session = Unmanaged<AudioCaptureSession>.fromOpaque(raw).takeUnretainedValue()
        guard session.enterCallback() else { return noErr }
        defer { session.leaveCallback() }
        return session.render(actionFlags: actionFlags, timeStamp: timeStamp, busNumber: busNumber, frames: frames)
    }

    /// Returns a strong control-plane snapshot while router admission prevents
    /// deactivation from releasing the unmanaged target underneath it. Callers
    /// must perform cleanup only after releasing any lifecycle control lock.
    func currentSessionSnapshot() -> AudioCaptureSession? {
        guard enterCallback() else { return nil }
        defer { leaveCallback() }
        let pointer = sessionPointer.load(ordering: .acquiring)
        guard pointer != 0, let raw = UnsafeMutableRawPointer(bitPattern: pointer) else { return nil }
        return Unmanaged<AudioCaptureSession>.fromOpaque(raw).takeUnretainedValue()
    }

    private func enterCallback() -> Bool {
        while true {
            let state = callbackState.load(ordering: .acquiring)
            guard state & Self.closedBit == 0 else { return false }
            guard state & Self.callbackCountMask < Self.callbackCountMask else { return false }
            if callbackState.compareExchange(
                expected: state,
                desired: state &+ 1,
                ordering: .acquiringAndReleasing
            ).exchanged { return true }
        }
    }

    private func leaveCallback() {
        callbackState.wrappingSubtract(1, ordering: .releasing)
    }

    private func closeAdmission() {
        while true {
            let state = callbackState.load(ordering: .acquiring)
            guard state & Self.closedBit == 0 else { return }
            if callbackState.compareExchange(
                expected: state,
                desired: state | Self.closedBit,
                ordering: .acquiringAndReleasing
            ).exchanged { return }
        }
    }

    private func waitForCallbacks() {
        while callbackState.load(ordering: .acquiring) & Self.callbackCountMask != 0 {
            sched_yield()
        }
    }
}

/// Per-run state retained by the service while the native callback is installed.
/// The callback never reaches back into `AudioCaptureService`, so stopping one
/// run cannot expose another run's unit, format, or stream continuation.
///
/// The callback is deliberately limited to an atomic admission check, a
/// preallocated `AudioUnitRender`, and a lock-free ring publication. Buffer
/// allocation, gain, RMS, level delivery, and AsyncStream yielding all happen
/// on the detached publisher.
internal final class AudioCaptureSession: @unchecked Sendable {
    static let ringCapacity = 8
    static let streamBufferCapacity = 8

    let lifecycle: AudioUnitLifecycle
    let format: AVAudioFormat?
    var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    let levelHandler: (@Sendable (Float) -> Void)?
    let spectrumHandler: (@Sendable (AudioSpectrum) -> Void)?
    let levelEmissionIntervalNanos: UInt64
    let ring: AudioChunkRing
    private let spectrumAnalyzer = AudioSpectrumAnalyzer()

    private let callbackState = Atomic<UInt64>(0)
    private let cleanupState = Atomic<Bool>(false)
    private let cleanupFinished = Atomic<Bool>(false)
    private let streamTerminated = Atomic<Bool>(false)
    private let publisherStartedState = Atomic<Bool>(false)
    private let firstPCMPublished = Atomic<Bool>(false)
    private let createdAt = DispatchTime.now().uptimeNanoseconds
    private let streamDropped = Atomic<UInt64>(0)
    private let allocationFailures = Atomic<UInt64>(0)
    private let publisherCompletion = DispatchSemaphore(value: 0)
    private let fatalRenderRequested = Atomic<Bool>(false)
    private let publisherSleep: @Sendable (UInt64) async -> Void

    private var captureGain: AdaptiveCaptureGain
    private var lastLevelEmissionNanos: UInt64 = 0
    private var publisherTask: Task<Void, Never>?
    private var publisherStarted = false

    private static let admissionClosedBit: UInt64 = 1 << 63
    private static let callbackCountMask: UInt64 = admissionClosedBit - 1
    internal static let fatalRenderStatus: OSStatus = OSStatus(paramErr)

    init(lifecycle: AudioUnitLifecycle,
         format: AVAudioFormat?,
         continuation: AsyncStream<AVAudioPCMBuffer>.Continuation,
         levelHandler: (@Sendable (Float) -> Void)?,
         spectrumHandler: (@Sendable (AudioSpectrum) -> Void)? = nil,
         usesBluetoothInput: Bool,
         ring: AudioChunkRing? = nil,
         levelEmissionIntervalNanos: UInt64 = 16_000_000,
         publisherSleep: @escaping @Sendable (UInt64) async -> Void = { delay in
             try? await Task.sleep(nanoseconds: delay)
         }) {
        self.lifecycle = lifecycle
        self.format = format
        self.continuation = continuation
        self.levelHandler = levelHandler
        self.spectrumHandler = spectrumHandler
        self.levelEmissionIntervalNanos = levelEmissionIntervalNanos
        self.publisherSleep = publisherSleep
        self.captureGain = usesBluetoothInput ? .bluetoothSpeechBoost : .disabled
        self.ring = ring ?? AudioChunkRing(maxFrames: 1, channelCount: 1, capacity: 1)
    }

    internal var droppedStreamCount: UInt64 {
        streamDropped.load(ordering: .acquiring)
    }

    internal var bufferAllocationFailureCount: UInt64 {
        allocationFailures.load(ordering: .acquiring)
    }

    internal var lossDiagnostics: AudioCaptureLoss {
        AudioCaptureLoss(ringDrops: ring.droppedNewestCount,
                         oversizedSlices: ring.oversizedSliceCount,
                         streamDrops: droppedStreamCount,
                         allocationFailures: bufferAllocationFailureCount)
    }

    /// Installs stream cancellation handling before the stream is returned to
    /// the consumer. The handler marks termination first, allowing a publisher
    /// that is currently polling an empty ring to exit before cleanup waits.
    func installTerminationHandler() {
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.streamTerminated.store(true, ordering: .releasing)
            // A running publisher performs cleanup after it has signalled its
            // completion semaphore. This avoids a re-entrant deadlock if
            // AsyncStream invokes this handler while `yield` returns `.terminated`.
            if !self.publisherStartedState.load(ordering: .acquiring),
               !self.cleanupState.load(ordering: .acquiring) {
                self.cleanup()
            }
        }
    }

    /// Starts the non-realtime publisher. The task owns no callback resources;
    /// the session remains retained by `AudioCaptureService` until cleanup has
    /// closed admission and waited for this task to drain.
    func startPublisher() {
        guard !publisherStarted else { return }
        publisherStarted = true
        publisherStartedState.store(true, ordering: .releasing)
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.publisherLoop()
        }
        publisherTask = task
    }

    /// Stops and releases the native unit before completing the stream. Calls are
    /// control-side and intentionally idempotent so failed starts and stream
    /// cancellation cannot double-dispose a unit.
    func cleanup() {
        cleanup(waitForPublisher: true)
    }

    private func cleanup(waitForPublisher: Bool) {
        guard !cleanupState.exchange(true, ordering: .acquiringAndReleasing) else {
            if waitForPublisher {
                while !cleanupFinished.load(ordering: .acquiring) {
                    sched_yield()
                }
            }
            return
        }
        defer { cleanupFinished.store(true, ordering: .releasing) }

        closeCallbackAdmission()
        waitForCallbacks()
        let owner = String(describing: ObjectIdentifier(self))
        AudioPhaseTiming.measure("native_stop", owner: owner) { lifecycle.stop() }
        // A stopped but initialized VPIO can retain voice-processing/output
        // resources. Release the entire graph on every stop, including the
        // first PTT release, before completing the stream.
        AudioPhaseTiming.measure("native_uninitialize", owner: owner) { lifecycle.uninitialize() }
        AudioPhaseTiming.measure("native_dispose", owner: owner) { lifecycle.dispose() }

        // No callback can publish after the admission wait. The publisher may
        // still own queued slots, so close first and let it drain before the
        // final control-side safety drain.
        ring.close()
        if publisherStarted, waitForPublisher {
            publisherCompletion.wait()
            publisherTask = nil
        }
        ring.drain()

        // Level zero is delivered off the CoreAudio callback before stream
        // completion, including when cancellation initiated cleanup.
        levelHandler?(0)
        spectrumHandler?(.zero)
        continuation.finish()
    }

    internal var fatalRenderCleanupRequested: Bool {
        fatalRenderRequested.load(ordering: .acquiring)
    }

    internal var cleanupRequested: Bool {
        cleanupState.load(ordering: .acquiring)
    }

    /// The callback's admission gate. A single CAS combines the closed bit and
    /// in-flight count, preventing a close/wait race from admitting a callback
    /// after the control plane observed zero in-flight callbacks.
    func enterCallback() -> Bool {
        while true {
            let state = callbackState.load(ordering: .acquiring)
            guard state & Self.admissionClosedBit == 0 else { return false }
            let count = state & Self.callbackCountMask
            guard count < Self.callbackCountMask else { return false }
            let result = callbackState.compareExchange(
                expected: state,
                desired: state &+ 1,
                ordering: .acquiringAndReleasing
            )
            if result.exchanged { return true }
        }
    }

    func leaveCallback() {
        callbackState.wrappingSubtract(1, ordering: .releasing)
    }

    /// Pulls one slice of input audio into a preallocated ring slot. No
    /// AVAudioPCMBuffer, AsyncStream, task, queue, lock, or sample processing
    /// occurs on this path.
    func render(actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                timeStamp: UnsafePointer<AudioTimeStamp>,
                busNumber: UInt32,
                frames: UInt32) -> OSStatus {
        guard !fatalRenderRequested.load(ordering: .acquiring) else {
            return Self.fatalRenderStatus
        }
        let reservationResult = ring.beginWrite(
            frames: frames,
            channelCount: UInt32(ring.channelCount)
        )
        switch reservationResult {
        case .full:
            // A full queue drops the newest slice, but the HAL input pull must
            // still be consumed. Render into the preallocated sink so the
            // callback does not leave input pending or overwrite old audio.
            guard let discard = ring.discardBufferList(
                frames: frames,
                channelCount: UInt32(ring.channelCount)
            ) else { return noErr }
            return lifecycle.render(
                actionFlags: actionFlags,
                timeStamp: timeStamp,
                busNumber: busNumber,
                frames: frames,
                data: discard
            )
        case .oversized:
            // Oversized slices cannot safely be rendered into fixed storage;
            // signal the publisher to clean up away from the realtime callback.
            fatalRenderRequested.store(true, ordering: .releasing)
            return Self.fatalRenderStatus
        case .closed:
            return noErr
        case .reserved(let reservation):
            let status = lifecycle.render(
                actionFlags: actionFlags,
                timeStamp: timeStamp,
                busNumber: busNumber,
                frames: frames,
                data: ring.audioBufferList(for: reservation)
            )
            guard status == noErr else {
                ring.abandonWrite(reservation)
                return status
            }
            ring.commitWrite(reservation)
            return noErr
        }
    }

    /// Deterministic support seam for focused tests. It runs the same
    /// publisher-side copy/gain/level/yield path without waiting on a task.
    internal func publishAvailableChunksForTesting() {
        drainPublishedChunks()
    }

    private func closeCallbackAdmission() {
        while true {
            let state = callbackState.load(ordering: .acquiring)
            guard state & Self.admissionClosedBit == 0 else { return }
            let result = callbackState.compareExchange(
                expected: state,
                desired: state | Self.admissionClosedBit,
                ordering: .acquiringAndReleasing
            )
            if result.exchanged { return }
        }
    }

    private func waitForCallbacks() {
        while callbackState.load(ordering: .acquiring) & Self.callbackCountMask != 0 {
            sched_yield()
        }
    }

    private func publisherLoop() async {
        defer {
            publisherCompletion.signal()
            if streamTerminated.load(ordering: .acquiring),
               !cleanupState.load(ordering: .acquiring) {
                cleanup(waitForPublisher: false)
            }
        }

        var idleDelay: UInt64 = 1_000_000
        var maximumIdleDelay: UInt64 = 1_000_000
        var smallestFrameCount = Int.max
        while true {
            if fatalRenderRequested.load(ordering: .acquiring) {
                cleanup(waitForPublisher: false)
                return
            }
            var processedAny = false
            while let chunk = ring.pop() {
                processedAny = true
                smallestFrameCount = min(smallestFrameCount, chunk.frameCount)
                if let rate = format?.sampleRate, rate.isFinite, rate > 0 {
                    // Never wait longer than half the smallest observed slice
                    // (with the original 1 ms floor and a 4 ms absolute cap).
                    let nanos = Double(smallestFrameCount) / rate * 500_000_000
                    maximumIdleDelay = UInt64(min(4_000_000, max(1_000_000, nanos)))
                }
                idleDelay = 1_000_000
                publish(chunk)
            }

            if fatalRenderRequested.load(ordering: .acquiring) {
                cleanup(waitForPublisher: false)
                return
            }

            if streamTerminated.load(ordering: .acquiring) || ring.isClosed {
                // `publish` releases every chunk even after stream cancellation;
                // the loop only exits once all currently visible slots are
                // consumed, preserving close/drain ordering.
                while let chunk = ring.pop() {
                    ring.release(chunk)
                }
                return
            }

            if !processedAny {
                // The callback has no wake-up primitive on its realtime path;
                // short publisher-side sleeps avoid a hot spin while retaining
                // bounded shutdown once `ring.close()` is observed.
                await publisherSleep(idleDelay)
                idleDelay = min(maximumIdleDelay, idleDelay * 2)
            }
        }
    }

    private func drainPublishedChunks() {
        while let chunk = ring.pop() {
            publish(chunk)
        }
    }

    private func publish(_ chunk: AudioChunkRing.Chunk) {
        defer { ring.release(chunk) }
        guard !streamTerminated.load(ordering: .acquiring) else { return }
        guard let format,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(chunk.frameCount)
              ),
              let channels = buffer.floatChannelData else {
            allocationFailures.wrappingAdd(1, ordering: .relaxed)
            return
        }

        buffer.frameLength = AVAudioFrameCount(chunk.frameCount)
        let destinationChannels = min(chunk.channelCount, Int(buffer.format.channelCount))
        let sourceChannels = chunk.channelData
        for channelIndex in 0..<destinationChannels {
            channels[channelIndex].update(
                from: sourceChannels[channelIndex],
                count: chunk.frameCount
            )
        }

        // Bluetooth gain and RMS are intentionally publisher-side work. This
        // also guarantees each yielded buffer is a unique retained instance.
        applyCaptureGain(to: buffer)
        emitLevel(from: buffer)

        switch continuation.yield(buffer) {
        case .enqueued:
            if !firstPCMPublished.exchange(true, ordering: .relaxed) {
                AudioPhaseTiming.record("first_published_pcm",
                                        owner: String(describing: ObjectIdentifier(self)), since: createdAt)
            }
        case .dropped:
            streamDropped.wrappingAdd(1, ordering: .relaxed)
        case .terminated:
            streamTerminated.store(true, ordering: .releasing)
        @unknown default:
            break
        }
    }

    private func applyCaptureGain(to buffer: AVAudioPCMBuffer) {
        guard captureGain.isEnabled, let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frames > 0, channelCount > 0 else { return }

        var sumSquares: Float = 0
        for channelIndex in 0..<channelCount {
            let channel = channels[channelIndex]
            for frame in 0..<frames {
                let sample = channel[frame]
                sumSquares += sample * sample
            }
        }

        let sampleCount = Float(frames * channelCount)
        let rms = (sumSquares / sampleCount).squareRoot()
        let gain = captureGain.nextGain(forRMS: rms)
        guard gain > 1.001 else { return }

        for channelIndex in 0..<channelCount {
            let channel = channels[channelIndex]
            for frame in 0..<frames {
                channel[frame] = softLimit(channel[frame] * gain)
            }
        }
    }

    private func softLimit(_ sample: Float) -> Float {
        // Smoothly constrain boosted speech without the harsh edge of hard clipping.
        tanhf(sample)
    }

    private func emitLevel(from buffer: AVAudioPCMBuffer) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastLevelEmissionNanos >= levelEmissionIntervalNanos else { return }
        lastLevelEmissionNanos = now

        let spectrum = spectrumAnalyzer.analyze(buffer: buffer)
        levelHandler?(spectrum.level)
        spectrumHandler?(spectrum)
    }
}

/// Captures microphone audio with a dedicated CoreAudio I/O backend pinned to a
/// specific device, and exposes two things:
///   • an AsyncStream of PCM buffers for the transcription engine, and
///   • a normalized RMS level (0...1) for the ferrofluid visualizer.
///
/// Ordinary capture uses an input-only HAL unit. Opt-in audio ducking uses a
/// full-duplex VoiceProcessingIO unit with a silent output renderer so macOS
/// applies native other-audio ducking without changing the system volume.
///
/// Why not AVAudioEngine: its input node always binds the *system default* input
/// and rebuilds an aggregate around it, so it cannot reliably capture from the
/// built-in mic while a Bluetooth headset is the default. Opening the headset's
/// mic forces it from A2DP into 16 kHz HFP, wrecking music playback. A HAL unit
/// lets us target the built-in mic directly, so the headset stays in A2DP and
/// playback is never degraded. Disposing the unit on stop fully releases the
/// device.
///
/// The render callback only copies into the fixed ring. A detached publisher
/// owns PCM allocation, Bluetooth gain, RMS throttling, `onLevel`, and stream
/// delivery, so consumers never retain a buffer that the callback may reuse.
public final class AudioCaptureService: AudioCapturing, @unchecked Sendable {
    private var activeSession: AudioCaptureSession?
    private var activeBackend: AudioCaptureBackend?
    private let backendFactory: AudioCaptureBackendFactory
    private let inputDeviceOverride: AudioDeviceID?
    private let controlLock = NSRecursiveLock()
    private var activeDiagnostics: AudioCaptureDiagnostics?

    internal private(set) var lastDiagnostics: AudioCaptureDiagnostics?
    internal private(set) var lastCleanupStatus = AudioUnitCleanupStatus.successful

    public var onLevel: (@Sendable (Float) -> Void)?
    public var onSpectrum: (@Sendable (AudioSpectrum) -> Void)?

    public init() {
        backendFactory = NativeAudioCaptureBackendFactory()
        inputDeviceOverride = nil
    }

    // Internal seam for lifecycle tests; production construction uses the
    // public no-argument initializer and creates sessions in start().
    internal init(activeSession: AudioCaptureSession?) {
        backendFactory = NativeAudioCaptureBackendFactory()
        inputDeviceOverride = nil
        self.activeSession = activeSession
    }

    // Internal seam for backend selection and startup failure tests.
    internal init(
        backendFactory: AudioCaptureBackendFactory,
        inputDeviceOverride: AudioDeviceID? = nil
    ) {
        self.backendFactory = backendFactory
        self.inputDeviceOverride = inputDeviceOverride
    }

    deinit {
        controlLock.lock()
        cleanupCaptureLocked()
        controlLock.unlock()
    }

    public func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
            }
        default:
            return false
        }
    }

    public func start(configuration: AudioCaptureConfiguration) throws -> AsyncStream<AVAudioPCMBuffer> {
        controlLock.lock()
        defer { controlLock.unlock() }
        stopLocked()

        var backendForCleanup: AudioCaptureBackend?
        do {
            let selection = try inputDeviceOverride.map { (id: $0, uid: Optional<String>.none) }
                ?? chosenInputDevice(configuration: configuration)
            let device = selection.id
            let backend = try backendFactory.makeBackend(configuration: configuration, inputDevice: device)
            backendForCleanup = backend
            let owner = String(describing: ObjectIdentifier(backend.lifecycle))
            try AudioPhaseTiming.measure("native_prepare", owner: owner) { try backend.prepare() }
            activeDiagnostics = backend.diagnostics.with(selectedInputUID: selection.uid)
            lastDiagnostics = activeDiagnostics
            if backend.usesBluetoothInput {
                NSLog("Nuvi/audio: Bluetooth input selected; applying speech gain while macOS uses hands-free/HFP quality")
            }

            let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(
                bufferingPolicy: .bufferingOldest(AudioCaptureSession.streamBufferCapacity)
            )
            let ring = AudioChunkRing(
                maxFrames: Int(backend.maximumFramesPerSlice),
                channelCount: backend.captureChannelCount,
                capacity: AudioCaptureSession.ringCapacity
            )
            let session = AudioCaptureSession(
                lifecycle: backend.lifecycle,
                format: backend.captureFormat,
                continuation: continuation,
                levelHandler: onLevel,
                spectrumHandler: onSpectrum,
                usesBluetoothInput: backend.usesBluetoothInput,
                ring: ring
            )
            activeSession = session
            activeBackend = backend
            session.installTerminationHandler()
            session.startPublisher()
            backendForCleanup = nil

            try backend.installCallbacks(for: session)
            try AudioPhaseTiming.measure("native_start", owner: owner) { try backend.start() }
            guard !session.cleanupRequested else {
                throw configuration.duckOtherAudio
                    ? AudioCaptureError.nativeDuckingUnavailable(
                        nativeDuckingUnavailableMessage("The audio route changed during startup")
                    )
                    : AudioCaptureError.microphoneInUse
            }
            activeDiagnostics = backend.diagnostics.with(selectedInputUID: selection.uid)
            lastDiagnostics = activeDiagnostics
            NSLog("Nuvi/audio: capture started")
            return stream
        } catch let error as AudioCaptureError {
            cleanupCaptureLocked()
            cleanup(backend: backendForCleanup)
            throw error
        } catch {
            cleanupCaptureLocked()
            cleanup(backend: backendForCleanup)
            NSLog("Nuvi/audio: failed to start microphone capture: \(String(describing: error))")
            if configuration.duckOtherAudio {
                throw AudioCaptureError.nativeDuckingUnavailable(
                    nativeDuckingUnavailableMessage(String(describing: error))
                )
            }
            throw AudioCaptureError.microphoneInUse
        }
    }

    public func stop() {
        controlLock.lock()
        let hadSession = stopLocked()
        controlLock.unlock()
        if !hadSession {
            onLevel?(0)
            onSpectrum?(.zero)
        }
    }

    @discardableResult
    private func stopLocked() -> Bool {
        cleanupCaptureLocked()
    }

    @discardableResult
    private func cleanupCaptureLocked() -> Bool {
        // Detach first. The local strong references keep the callback-owned
        // session and backend alive through ordered stop/publisher drain.
        let session = activeSession
        let backend = activeBackend
        activeSession = nil
        activeBackend = nil
        guard let session else {
            activeDiagnostics = nil
            return false
        }
        defer {
            let loss = session.lossDiagnostics
            if loss.hasLoss {
                NSLog("Nuvi/audio: capture loss ring=%llu oversized=%llu stream=%llu allocation=%llu",
                      loss.ringDrops, loss.oversizedSlices, loss.streamDrops, loss.allocationFailures)
            }
        }
        guard let backend else {
            session.cleanup()
            lastCleanupStatus = session.lifecycle.cleanupStatus
            activeDiagnostics = nil
            return true
        }

        let diagnostics = activeDiagnostics
        session.cleanup()
        backend.releaseSessionCallback()
        // Retry incomplete native teardown through the existing quarantine
        // policy; never keep an initialized unit as an idle optimization.
        cleanup(backend: backend)
        let status = session.lifecycle.cleanupStatus
        lastCleanupStatus = status
        if let diagnostics {
            lastDiagnostics = diagnostics.with(cleanupComplete: status.isComplete,
                                               loss: session.lossDiagnostics)
        }
        activeDiagnostics = nil
        return true
    }

    private func cleanup(backend: AudioCaptureBackend?) {
        guard let backend else { return }
        backend.cleanup()
        let status = backend.lifecycle.cleanupStatus
        lastCleanupStatus = status
        lastDiagnostics = backend.diagnostics.with(cleanupComplete: status.isComplete)
        activeDiagnostics = nil
    }

    // MARK: - Device selection

    private func chosenInputDevice(
        configuration: AudioCaptureConfiguration
    ) throws -> (id: AudioDeviceID, uid: String?) {
        switch SettingsStore.shared.inputDeviceUID {
        case "":
            // Automatic: prefer built-in so a Bluetooth headset stays in A2DP.
            if let builtIn = AudioInputDevice.builtInInputDeviceID() {
                NSLog("Nuvi/audio: input=automatic (built-in id=\(builtIn))")
                return (builtIn, nil)
            }
            if let device = AudioInputDevice.defaultInputDeviceID() {
                return (device, nil)
            }
            throw AudioCaptureError.microphoneUnavailable("No input device is available")
        case "default":
            guard let device = AudioInputDevice.defaultInputDeviceID() else {
                throw AudioCaptureError.microphoneUnavailable("No system default input device is available")
            }
            NSLog("Nuvi/audio: input=system default (id=\(device))")
            return (device, nil)
        case let uid:
            if let device = AudioInputDevice.deviceID(forUID: uid) {
                NSLog("Nuvi/audio: input=pinned uid=\(uid) (id=\(device))")
                return (device, uid)
            }
            NSLog("Nuvi/audio: selected input device unavailable; refusing substitution")
            let detail = "The selected input device UID \(uid) is unavailable"
            if configuration.duckOtherAudio {
                throw AudioCaptureError.nativeDuckingUnavailable(
                    nativeDuckingUnavailableMessage(detail)
                )
            }
            throw AudioCaptureError.microphoneUnavailable(detail)
        }
    }

}

private struct AdaptiveCaptureGain {
    static let disabled = AdaptiveCaptureGain(isEnabled: false)
    static let bluetoothSpeechBoost = AdaptiveCaptureGain(isEnabled: true)

    let isEnabled: Bool
    private let targetRMS: Float = 0.11
    private let noiseFloorRMS: Float = 0.006
    private let maxGain: Float = 8
    private let attack: Float = 0.35
    private let release: Float = 0.08
    private var currentGain: Float = 1

    private init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    mutating func nextGain(forRMS rms: Float) -> Float {
        guard isEnabled, rms >= noiseFloorRMS else {
            currentGain += (1 - currentGain) * release
            return currentGain
        }

        let desiredGain = min(maxGain, max(1, targetRMS / max(rms, 0.000_001)))
        let coefficient = desiredGain > currentGain ? attack : release
        currentGain += (desiredGain - currentGain) * coefficient
        return currentGain
    }
}

/// C render callback. Forwards to the callback-owned session via the ref-con pointer.
internal func captureRenderCallback(refCon: UnsafeMutableRawPointer,
                                    actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                    timeStamp: UnsafePointer<AudioTimeStamp>,
                                    busNumber: UInt32,
                                    frames: UInt32,
                                    data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let router = Unmanaged<AudioCaptureCallbackRouter>.fromOpaque(refCon).takeUnretainedValue()
    return router.render(actionFlags: actionFlags, timeStamp: timeStamp, busNumber: busNumber, frames: frames)
}

/// Supplies the enabled VPIO output bus with real silence. This callback is
/// intentionally context-free and realtime-safe: it only clears the bytes the
/// audio unit supplied and sets the corresponding silence hint.
internal func silenceRenderCallback(refCon: UnsafeMutableRawPointer,
                                    actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                    timeStamp: UnsafePointer<AudioTimeStamp>,
                                    busNumber: UInt32,
                                    frames: UInt32,
                                    data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    _ = refCon
    _ = timeStamp
    _ = busNumber
    _ = frames

    if let data {
        let buffers = UnsafeMutableAudioBufferListPointer(data)
        for index in 0..<buffers.count {
            let buffer = buffers[index]
            if let address = buffer.mData, buffer.mDataByteSize > 0 {
                memset(address, 0, Int(buffer.mDataByteSize))
            }
        }
    }
    actionFlags.pointee.formUnion(AudioUnitRenderActionFlags(rawValue: 1 << 4))
    return noErr
}
