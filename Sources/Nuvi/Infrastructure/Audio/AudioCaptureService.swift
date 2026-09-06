import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import Darwin
import Synchronization

/// Port for microphone capture. Keeping the controller on this abstraction lets
/// tests drive dictation without touching real hardware.
public enum AudioCaptureError: Error, Sendable, Equatable {
    case microphoneInUse
    case microphoneUnavailable(String)
}

public protocol AudioCapturing: AnyObject, Sendable {
    var onLevel: (@Sendable (Float) -> Void)? { get set }
    var onSpectrum: (@Sendable (AudioSpectrum) -> Void)? { get set }
    func requestPermission() async -> Bool
    func start() throws -> AsyncStream<AVAudioPCMBuffer>
    func stop()
}

public extension AudioCapturing {
    var onSpectrum: (@Sendable (AudioSpectrum) -> Void)? {
        get { nil }
        set {}
    }
}

/// The control-plane lifecycle for one HAL instance. The render callback only
/// reads the immutable `unit` reference; cleanup is kept on the control side.
internal protocol AudioUnitLifecycle: AnyObject {
    var unit: AudioUnit? { get }
    func stop()
    func uninitialize()
    func dispose()
}

private final class HALAudioUnitLifecycle: AudioUnitLifecycle, @unchecked Sendable {
    let unit: AudioUnit?

    init(unit: AudioUnit) {
        self.unit = unit
    }

    func stop() {
        guard let unit else { return }
        _ = AudioOutputUnitStop(unit)
    }

    func uninitialize() {
        guard let unit else { return }
        _ = AudioUnitUninitialize(unit)
    }

    func dispose() {
        guard let unit else { return }
        _ = AudioComponentInstanceDispose(unit)
    }
}

/// Per-run state retained by the service while the HAL callback is installed.
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
    private let streamTerminated = Atomic<Bool>(false)
    private let publisherStartedState = Atomic<Bool>(false)
    private let streamDropped = Atomic<UInt64>(0)
    private let allocationFailures = Atomic<UInt64>(0)
    private let publisherCompletion = DispatchSemaphore(value: 0)

    private var captureGain: AdaptiveCaptureGain
    private var lastLevelEmissionNanos: UInt64 = 0
    private var publisherTask: Task<Void, Never>?
    private var publisherStarted = false

    private static let admissionClosedBit: UInt64 = 1 << 63
    private static let callbackCountMask: UInt64 = admissionClosedBit - 1

    init(lifecycle: AudioUnitLifecycle,
         format: AVAudioFormat?,
         continuation: AsyncStream<AVAudioPCMBuffer>.Continuation,
         levelHandler: (@Sendable (Float) -> Void)?,
         spectrumHandler: (@Sendable (AudioSpectrum) -> Void)? = nil,
         usesBluetoothInput: Bool,
         ring: AudioChunkRing? = nil,
         levelEmissionIntervalNanos: UInt64 = 50_000_000) {
        self.lifecycle = lifecycle
        self.format = format
        self.continuation = continuation
        self.levelHandler = levelHandler
        self.spectrumHandler = spectrumHandler
        self.levelEmissionIntervalNanos = levelEmissionIntervalNanos
        self.captureGain = usesBluetoothInput ? .bluetoothSpeechBoost : .disabled
        self.ring = ring ?? AudioChunkRing(maxFrames: 1, channelCount: 1, capacity: 1)
    }

    internal var droppedStreamCount: UInt64 {
        streamDropped.load(ordering: .acquiring)
    }

    internal var bufferAllocationFailureCount: UInt64 {
        allocationFailures.load(ordering: .acquiring)
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
            if !self.publisherStartedState.load(ordering: .acquiring) {
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

    /// Stops the HAL before completing the stream. Calls are control-side and
    /// intentionally idempotent so failed starts and stream cancellation
    /// cannot double-dispose a unit.
    func cleanup() {
        guard !cleanupState.exchange(true, ordering: .acquiringAndReleasing) else { return }

        closeCallbackAdmission()
        lifecycle.stop()
        waitForCallbacks()
        lifecycle.uninitialize()
        lifecycle.dispose()

        // No callback can publish after the admission wait. The publisher may
        // still own queued slots, so close first and let it drain before the
        // final control-side safety drain.
        ring.close()
        if publisherStarted {
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
        guard let unit = lifecycle.unit else { return noErr }
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
            return AudioUnitRender(unit, actionFlags, timeStamp, busNumber, frames, discard)
        case .oversized, .closed:
            // Oversized slices cannot safely be rendered into fixed storage;
            // they are counted by the ring and dropped without resizing.
            return noErr
        case .reserved(let reservation):
            let status = AudioUnitRender(
                unit,
                actionFlags,
                timeStamp,
                busNumber,
                frames,
                ring.audioBufferList(for: reservation)
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
                // The completion signal is already available, so cleanup can
                // synchronously finish lifecycle disposal without waiting on
                // this task (which is the current execution context).
                cleanup()
            }
        }

        while true {
            var processedAny = false
            while let chunk = ring.pop() {
                processedAny = true
                publish(chunk)
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
                try? await Task.sleep(nanoseconds: 1_000_000)
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
            break
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

/// Captures microphone audio with a dedicated CoreAudio HAL I/O unit (AUHAL)
/// pinned to a specific device, and exposes two things:
///   • an AsyncStream of PCM buffers for the transcription engine, and
///   • a normalized RMS level (0...1) for the ferrofluid visualizer.
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

    public var onLevel: (@Sendable (Float) -> Void)?
    public var onSpectrum: (@Sendable (AudioSpectrum) -> Void)?

    public init() {}

    // Internal seam for lifecycle tests; production construction uses the
    // public no-argument initializer and creates sessions in start().
    internal init(activeSession: AudioCaptureSession?) {
        self.activeSession = activeSession
    }

    deinit {
        cleanupCapture()
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

    public func start() throws -> AsyncStream<AVAudioPCMBuffer> {
        stop()

        var lifecycle: AudioUnitLifecycle?
        do {
            let unit = try makeInputUnit()
            let liveLifecycle = HALAudioUnitLifecycle(unit: unit)
            lifecycle = liveLifecycle

            let device = chosenInputDevice()
            try setCurrentDevice(device, on: unit)
            let usesBluetoothInput = AudioInputDevice.isBluetoothInputDevice(device)
            if usesBluetoothInput {
                NSLog("Nuvi/audio: Bluetooth input selected; applying speech gain while macOS uses hands-free/HFP quality")
            }

            // Hardware format on the input element drives the client format we ask
            // the unit to deliver: same rate and channel count, but plain Float32 so
            // downstream conversion is trivial.
            let hardware = try inputStreamFormat(of: unit)
            guard hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0 else {
                throw AudioCaptureError.microphoneInUse
            }
            var asbd = makeClientFormat(sampleRate: hardware.mSampleRate,
                                        channels: hardware.mChannelsPerFrame)
            try setClientFormat(asbd, on: unit)
            guard let avFormat = AVAudioFormat(streamDescription: &asbd) else {
                throw AudioCaptureError.microphoneInUse
            }
            let maximumFrames = try maximumFramesPerSlice(of: unit)
            NSLog("Nuvi/audio: HAL input device=\(device), sampleRate=\(avFormat.sampleRate), channels=\(avFormat.channelCount)")

            let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(
                // The ring and stream both use drop-newest semantics. Keeping
                // the oldest buffered values preserves temporal order when a
                // consumer falls behind.
                bufferingPolicy: .bufferingOldest(AudioCaptureSession.streamBufferCapacity)
            )
            let ring = AudioChunkRing(
                maxFrames: Int(maximumFrames),
                channelCount: Int(hardware.mChannelsPerFrame),
                capacity: AudioCaptureSession.ringCapacity
            )
            let session = AudioCaptureSession(
                lifecycle: liveLifecycle,
                format: avFormat,
                continuation: continuation,
                levelHandler: onLevel,
                spectrumHandler: onSpectrum,
                usesBluetoothInput: usesBluetoothInput,
                ring: ring
            )
            activeSession = session
            session.installTerminationHandler()
            session.startPublisher()
            // From this point on, the session owns all callback state and the
            // catch path must clean it through `activeSession`.
            lifecycle = nil

            try setInputCallback(on: unit, session: session)

            var status = AudioUnitInitialize(unit)
            guard status == noErr else { throw AudioCaptureError.microphoneInUse }
            status = AudioOutputUnitStart(unit)
            guard status == noErr else { throw AudioCaptureError.microphoneInUse }

            NSLog("Nuvi/audio: capture started")
            return stream
        } catch let error as AudioCaptureError {
            cleanupCapture()
            cleanup(lifecycle)
            throw error
        } catch {
            cleanupCapture()
            cleanup(lifecycle)
            NSLog("Nuvi/audio: failed to start microphone capture: \(String(describing: error))")
            throw AudioCaptureError.microphoneInUse
        }
    }

    public func stop() {
        let hadSession = cleanupCapture()
        if !hadSession {
            onLevel?(0)
            onSpectrum?(.zero)
        }
    }

    @discardableResult
    private func cleanupCapture() -> Bool {
        // Detach first. The local strong reference keeps the callback-owned
        // session alive through stop/uninitialize/dispose.
        let session = activeSession
        activeSession = nil
        session?.cleanup()
        return session != nil
    }

    private func cleanup(_ lifecycle: AudioUnitLifecycle?) {
        guard let lifecycle else { return }
        lifecycle.stop()
        lifecycle.uninitialize()
        lifecycle.dispose()
    }

    // MARK: - Device selection

    private func chosenInputDevice() -> AudioDeviceID {
        let unknown = AudioDeviceID(kAudioObjectUnknown)
        switch SettingsStore.shared.inputDeviceUID {
        case "":
            // Automatic: prefer built-in so a Bluetooth headset stays in A2DP.
            if let builtIn = AudioInputDevice.builtInInputDeviceID() {
                NSLog("Nuvi/audio: input=automatic (built-in id=\(builtIn))")
                return builtIn
            }
            return AudioInputDevice.defaultInputDeviceID() ?? unknown
        case "default":
            let device = AudioInputDevice.defaultInputDeviceID() ?? unknown
            NSLog("Nuvi/audio: input=system default (id=\(device))")
            return device
        case let uid:
            if let device = AudioInputDevice.deviceID(forUID: uid) {
                NSLog("Nuvi/audio: input=pinned uid=\(uid) (id=\(device))")
                return device
            }
            NSLog("Nuvi/audio: selected input device unavailable; falling back to built-in/default")
            return AudioInputDevice.builtInInputDeviceID()
                ?? AudioInputDevice.defaultInputDeviceID() ?? unknown
        }
    }

    // MARK: - HAL unit plumbing

    private func makeInputUnit() throws -> AudioUnit {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioCaptureError.microphoneUnavailable("No HAL audio component")
        }
        var unit: AudioUnit?
        guard AudioComponentInstanceNew(component, &unit) == noErr, let unit else {
            throw AudioCaptureError.microphoneUnavailable("Could not create input unit")
        }

        // Enable input (element 1), disable output (element 0).
        var enable: UInt32 = 1
        try set(unit, kAudioOutputUnitProperty_EnableIO, .input, 1, &enable, UInt32(MemoryLayout<UInt32>.size))
        var disable: UInt32 = 0
        try set(unit, kAudioOutputUnitProperty_EnableIO, .output, 0, &disable, UInt32(MemoryLayout<UInt32>.size))
        return unit
    }

    private func setCurrentDevice(_ device: AudioDeviceID, on unit: AudioUnit) throws {
        guard device != AudioDeviceID(kAudioObjectUnknown) else {
            throw AudioCaptureError.microphoneUnavailable("No input device")
        }
        var value = device
        try set(unit, kAudioOutputUnitProperty_CurrentDevice, .global, 0, &value,
                UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    private func inputStreamFormat(of unit: AudioUnit) throws -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                          kAudioUnitScope_Input, 1, &format, &size)
        guard status == noErr else {
            throw AudioCaptureError.microphoneUnavailable("Could not read input format")
        }
        return format
    }

    private func maximumFramesPerSlice(of unit: AudioUnit) throws -> UInt32 {
        var maxFrames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioUnitGetProperty(
            unit,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &maxFrames,
            &size
        )
        guard status == noErr, maxFrames > 0 else {
            throw AudioCaptureError.microphoneUnavailable("Could not read maximum frames per slice")
        }
        return maxFrames
    }

    private func makeClientFormat(sampleRate: Float64, channels: UInt32) -> AudioStreamBasicDescription {
        let bytes = UInt32(MemoryLayout<Float32>.size)
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: bytes,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytes,
            mChannelsPerFrame: channels,
            mBitsPerChannel: bytes * 8,
            mReserved: 0
        )
    }

    private func setClientFormat(_ asbd: AudioStreamBasicDescription, on unit: AudioUnit) throws {
        var value = asbd
        try set(unit, kAudioUnitProperty_StreamFormat, .output, 1, &value,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
    }

    private func setInputCallback(on unit: AudioUnit, session: AudioCaptureSession) throws {
        var callback = AURenderCallbackStruct(
            inputProc: captureRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(session).toOpaque()
        )
        try set(unit, kAudioOutputUnitProperty_SetInputCallback, .global, 0, &callback,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size))
    }

    private enum Scope { case input, output, global }
    private func set(_ unit: AudioUnit, _ property: AudioUnitPropertyID, _ scope: Scope,
                     _ element: AudioUnitElement, _ value: UnsafeMutableRawPointer, _ size: UInt32) throws {
        let auScope: AudioUnitScope
        switch scope {
        case .input: auScope = kAudioUnitScope_Input
        case .output: auScope = kAudioUnitScope_Output
        case .global: auScope = kAudioUnitScope_Global
        }
        let status = AudioUnitSetProperty(unit, property, auScope, element, value, size)
        guard status == noErr else {
            throw AudioCaptureError.microphoneUnavailable("AudioUnitSetProperty \(property) failed: \(status)")
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
private func captureRenderCallback(refCon: UnsafeMutableRawPointer,
                                   actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                   timeStamp: UnsafePointer<AudioTimeStamp>,
                                   busNumber: UInt32,
                                   frames: UInt32,
                                   data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let session = Unmanaged<AudioCaptureSession>.fromOpaque(refCon).takeUnretainedValue()
    guard session.enterCallback() else { return noErr }
    defer { session.leaveCallback() }
    return session.render(actionFlags: actionFlags, timeStamp: timeStamp, busNumber: busNumber, frames: frames)
}
