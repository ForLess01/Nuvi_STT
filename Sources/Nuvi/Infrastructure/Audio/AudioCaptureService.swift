import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import Darwin

/// Port for microphone capture. Keeping the controller on this abstraction lets
/// tests drive dictation without touching real hardware.
public enum AudioCaptureError: Error, Sendable, Equatable {
    case microphoneInUse
    case microphoneUnavailable(String)
}

public protocol AudioCapturing: AnyObject, Sendable {
    var onLevel: (@Sendable (Float) -> Void)? { get set }
    func requestPermission() async -> Bool
    func start() throws -> AsyncStream<AVAudioPCMBuffer>
    func stop()
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
internal final class AudioCaptureSession: @unchecked Sendable {
    let lifecycle: AudioUnitLifecycle
    let format: AVAudioFormat?
    let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    let levelHandler: (@Sendable (Float) -> Void)?
    let levelEmissionIntervalNanos: UInt64

    // These values are written only by the render callback. They are not part
    // of service lifecycle state and are never reset from the control thread.
    private var captureGain: AdaptiveCaptureGain
    private var lastLevelEmissionNanos: UInt64 = 0
    private var didCleanup = false

    init(lifecycle: AudioUnitLifecycle,
         format: AVAudioFormat?,
         continuation: AsyncStream<AVAudioPCMBuffer>.Continuation,
         levelHandler: (@Sendable (Float) -> Void)?,
         usesBluetoothInput: Bool,
         levelEmissionIntervalNanos: UInt64 = 50_000_000) {
        self.lifecycle = lifecycle
        self.format = format
        self.continuation = continuation
        self.levelHandler = levelHandler
        self.levelEmissionIntervalNanos = levelEmissionIntervalNanos
        self.captureGain = usesBluetoothInput ? .bluetoothSpeechBoost : .disabled
    }

    /// Stops the HAL before completing the stream. Calls are control-side and
    /// intentionally idempotent so failed starts cannot double-dispose a unit.
    func cleanup() {
        guard !didCleanup else { return }
        didCleanup = true
        lifecycle.stop()
        lifecycle.uninitialize()
        lifecycle.dispose()
        continuation.finish()
    }

    /// Pulls one slice of input audio into a fresh PCM buffer and publishes it.
    /// Called on the audio render thread. The allocation/yield behavior remains
    /// unchanged in this lifecycle-hardening slice and is tracked separately.
    func render(actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                timeStamp: UnsafePointer<AudioTimeStamp>,
                busNumber: UInt32,
                frames: UInt32) -> OSStatus {
        guard let unit = lifecycle.unit,
              let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return noErr
        }
        buffer.frameLength = frames
        let status = AudioUnitRender(unit, actionFlags, timeStamp, busNumber, frames, buffer.mutableAudioBufferList)
        guard status == noErr else { return status }
        applyCaptureGain(to: buffer)
        continuation.yield(buffer)
        emitLevel(from: buffer)
        return noErr
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
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        var sum: Float = 0
        for i in 0..<frames {
            let sample = channel[i]
            sum += sample * sample
        }
        let rms = (sum / Float(frames)).squareRoot()
        // Perceptual-ish mapping: gain up quiet speech, clamp to 0...1.
        let level = min(1, max(0, rms * 12))
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastLevelEmissionNanos >= levelEmissionIntervalNanos else { return }
        lastLevelEmissionNanos = now
        levelHandler?(level)
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
/// The render callback runs on the audio thread, so `onLevel` is called there —
/// the consumer is responsible for hopping to the main actor.
public final class AudioCaptureService: AudioCapturing, @unchecked Sendable {
    private var activeSession: AudioCaptureSession?

    public var onLevel: (@Sendable (Float) -> Void)?

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
            NSLog("Nuvi/audio: HAL input device=\(device), sampleRate=\(avFormat.sampleRate), channels=\(avFormat.channelCount)")

            let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
            let session = AudioCaptureSession(
                lifecycle: liveLifecycle,
                format: avFormat,
                continuation: continuation,
                levelHandler: onLevel,
                usesBluetoothInput: usesBluetoothInput
            )
            activeSession = session
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
        cleanupCapture()
        onLevel?(0)
    }

    private func cleanupCapture() {
        // Detach first. The local strong reference keeps the callback-owned
        // session alive through stop/uninitialize/dispose.
        let session = activeSession
        activeSession = nil
        session?.cleanup()
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
    return session.render(actionFlags: actionFlags, timeStamp: timeStamp, busNumber: busNumber, frames: frames)
}
