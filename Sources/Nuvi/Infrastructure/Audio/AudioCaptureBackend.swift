import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import Darwin
import Synchronization

internal func nativeDuckingUnavailableMessage(_ detail: String) -> String {
    let guidance = "Audio Ducking is unavailable. Disable Audio Ducking or select a supported microphone."
    let detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
    return detail.isEmpty ? guidance : "\(guidance) \(detail)"
}

/// The two native capture paths exposed by the audio facade.
internal enum AudioCaptureBackendKind: String, Equatable, Sendable {
    case hal = "HAL"
    case voiceProcessingIO = "VoiceProcessingIO"
}

internal struct AudioFormatSnapshot: Equatable, Sendable {
    let sampleRate: Float64
    let formatID: UInt32
    let formatFlags: UInt32
    let bytesPerPacket: UInt32
    let framesPerPacket: UInt32
    let bytesPerFrame: UInt32
    let channelsPerFrame: UInt32
    let bitsPerChannel: UInt32

    init(_ format: AudioStreamBasicDescription) {
        sampleRate = format.mSampleRate
        formatID = format.mFormatID
        formatFlags = format.mFormatFlags
        bytesPerPacket = format.mBytesPerPacket
        framesPerPacket = format.mFramesPerPacket
        bytesPerFrame = format.mBytesPerFrame
        channelsPerFrame = format.mChannelsPerFrame
        bitsPerChannel = format.mBitsPerChannel
    }
}

internal struct AudioCaptureDiagnostics: Equatable, Sendable {
    let requestedBackend: AudioCaptureBackendKind
    let effectiveBackend: AudioCaptureBackendKind?
    let selectedInputUID: String?
    let selectedInputID: AudioDeviceID
    let boundInputID: AudioDeviceID?
    let boundOutputID: AudioDeviceID?
    let inputClientFormat: AudioFormatSnapshot?
    let outputClientFormat: AudioFormatSnapshot?
    let maximumFramesPerSlice: UInt32
    let cleanupComplete: Bool

    func with(
        selectedInputUID: String? = nil,
        effectiveBackend: AudioCaptureBackendKind? = nil,
        cleanupComplete: Bool? = nil
    ) -> AudioCaptureDiagnostics {
        AudioCaptureDiagnostics(
            requestedBackend: requestedBackend,
            effectiveBackend: effectiveBackend ?? self.effectiveBackend,
            selectedInputUID: selectedInputUID ?? self.selectedInputUID,
            selectedInputID: selectedInputID,
            boundInputID: boundInputID,
            boundOutputID: boundOutputID,
            inputClientFormat: inputClientFormat,
            outputClientFormat: outputClientFormat,
            maximumFramesPerSlice: maximumFramesPerSlice,
            cleanupComplete: cleanupComplete ?? self.cleanupComplete
        )
    }

    func withEffectiveFormats(
        inputClientFormat: AudioFormatSnapshot,
        outputClientFormat: AudioFormatSnapshot?,
        maximumFramesPerSlice: UInt32
    ) -> AudioCaptureDiagnostics {
        AudioCaptureDiagnostics(
            requestedBackend: requestedBackend,
            effectiveBackend: effectiveBackend,
            selectedInputUID: selectedInputUID,
            selectedInputID: selectedInputID,
            boundInputID: boundInputID,
            boundOutputID: boundOutputID,
            inputClientFormat: inputClientFormat,
            outputClientFormat: outputClientFormat,
            maximumFramesPerSlice: maximumFramesPerSlice,
            cleanupComplete: cleanupComplete
        )
    }
}

internal struct AudioUnitCleanupStatus: Equatable, Sendable {
    let stop: OSStatus?
    let uninitialize: OSStatus?
    let dispose: OSStatus?
    let failedListenerRemovals: Int

    var isComplete: Bool {
        stop == noErr
            && uninitialize == noErr
            && dispose == noErr
            && failedListenerRemovals == 0
    }

    static let successful = AudioUnitCleanupStatus(
        stop: noErr,
        uninitialize: noErr,
        dispose: noErr,
        failedListenerRemovals: 0
    )
}

/// A small handle wrapper keeps the production CoreAudio pointer behind the
/// injectable operations seam. Tests can exercise setup and cleanup without
/// manufacturing an actual audio unit or opening a device.
internal final class NativeAudioUnitHandle: @unchecked Sendable {
    let raw: AudioUnit?

    init(raw: AudioUnit?) {
        self.raw = raw
    }
}

/// The native calls used by both backend builders. Keeping these calls behind a
/// seam means failure, readback, callback, and lifecycle paths are tested with
/// the same builder used in production rather than with a disconnected fake
/// backend.
internal protocol AudioUnitNativeOperations: AnyObject {
    func makeUnit(componentSubType: UInt32) throws -> NativeAudioUnitHandle
    func setProperty(
        _ unit: NativeAudioUnitHandle,
        property: AudioUnitPropertyID,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        data: UnsafeMutableRawPointer,
        size: UInt32
    ) -> OSStatus
    func getProperty(
        _ unit: NativeAudioUnitHandle,
        property: AudioUnitPropertyID,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        data: UnsafeMutableRawPointer,
        size: inout UInt32
    ) -> OSStatus
    func initialize(_ unit: NativeAudioUnitHandle) -> OSStatus
    func start(_ unit: NativeAudioUnitHandle) -> OSStatus
    func stop(_ unit: NativeAudioUnitHandle) -> OSStatus
    func uninitialize(_ unit: NativeAudioUnitHandle) -> OSStatus
    func dispose(_ unit: NativeAudioUnitHandle) -> OSStatus
    func render(
        _ unit: NativeAudioUnitHandle,
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        busNumber: UInt32,
        frames: UInt32,
        data: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus
    func addPropertyListenerBlock(
        objectID: AudioObjectID,
        address: UnsafeMutablePointer<AudioObjectPropertyAddress>,
        queue: DispatchQueue,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus
    func removePropertyListenerBlock(
        objectID: AudioObjectID,
        address: UnsafeMutablePointer<AudioObjectPropertyAddress>,
        queue: DispatchQueue,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus
}

/// The device lookup required by the VPIO builder. It is deliberately read-only:
/// Nuvi never changes a system default device as part of ducking.
internal protocol AudioDeviceProvider: AnyObject {
    func defaultOutputDeviceID() -> AudioDeviceID?
    func isBluetoothInputDevice(_ device: AudioDeviceID) -> Bool
}

internal final class SystemAudioDeviceProvider: AudioDeviceProvider, @unchecked Sendable {
    func defaultOutputDeviceID() -> AudioDeviceID? {
        AudioInputDevice.defaultOutputDeviceID()
    }

    func isBluetoothInputDevice(_ device: AudioDeviceID) -> Bool {
        AudioInputDevice.isBluetoothInputDevice(device)
    }
}

/// A configured backend owns one audio unit until its lifecycle is transferred
/// into `AudioCaptureSession`.
internal protocol AudioCaptureBackend: AnyObject {
    var kind: AudioCaptureBackendKind { get }
    var lifecycle: AudioUnitLifecycle { get }
    var captureFormat: AVAudioFormat { get }
    var captureChannelCount: Int { get }
    var maximumFramesPerSlice: UInt32 { get }
    var usesBluetoothInput: Bool { get }
    var diagnostics: AudioCaptureDiagnostics { get }

    func installCallbacks(for session: AudioCaptureSession) throws
    func start() throws
    func cleanup()
}

internal protocol AudioCaptureBackendFactory: AnyObject {
    func makeBackend(
        configuration: AudioCaptureConfiguration,
        inputDevice: AudioDeviceID
    ) throws -> AudioCaptureBackend
}

/// The existing session uses this control-plane lifecycle abstraction. Render
/// and route-listener defaults keep lightweight session tests independent of
/// CoreAudio while the native lifecycle supplies the real implementation.
internal protocol AudioUnitLifecycle: AnyObject {
    var unit: AudioUnit? { get }
    var cleanupStatus: AudioUnitCleanupStatus { get }
    func render(
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        busNumber: UInt32,
        frames: UInt32,
        data: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus
    func installRouteListeners(
        inputDevice: AudioDeviceID,
        outputDevice: AudioDeviceID,
        onRouteChange: @escaping @Sendable () -> Void
    ) throws
    func stop()
    func uninitialize()
    func dispose()
}

internal extension AudioUnitLifecycle {
    var cleanupStatus: AudioUnitCleanupStatus { AudioUnitCleanupStatus.successful }

    func render(
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        busNumber: UInt32,
        frames: UInt32,
        data: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        _ = actionFlags
        _ = timeStamp
        _ = busNumber
        _ = frames
        _ = data
        return noErr
    }

    func installRouteListeners(
        inputDevice: AudioDeviceID,
        outputDevice: AudioDeviceID,
        onRouteChange: @escaping @Sendable () -> Void
    ) throws {
        _ = inputDevice
        _ = outputDevice
        _ = onRouteChange
    }
}

private final class SystemAudioUnitNativeOperations: AudioUnitNativeOperations, @unchecked Sendable {
    static let shared = SystemAudioUnitNativeOperations()

    func makeUnit(componentSubType: UInt32) throws -> NativeAudioUnitHandle {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: componentSubType,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioCaptureError.microphoneUnavailable("No matching native audio component")
        }

        var unit: AudioUnit?
        let status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr else {
            if let unit {
                _ = AudioComponentInstanceDispose(unit)
            }
            throw AudioCaptureError.microphoneUnavailable("Could not create native audio unit (status \(status))")
        }
        guard let unit else {
            throw AudioCaptureError.microphoneUnavailable("Could not create native audio unit")
        }
        return NativeAudioUnitHandle(raw: unit)
    }

    func setProperty(
        _ unit: NativeAudioUnitHandle,
        property: AudioUnitPropertyID,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        data: UnsafeMutableRawPointer,
        size: UInt32
    ) -> OSStatus {
        guard let raw = unit.raw else { return -50 }
        return AudioUnitSetProperty(raw, property, scope, element, data, size)
    }

    func getProperty(
        _ unit: NativeAudioUnitHandle,
        property: AudioUnitPropertyID,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        data: UnsafeMutableRawPointer,
        size: inout UInt32
    ) -> OSStatus {
        guard let raw = unit.raw else { return -50 }
        return AudioUnitGetProperty(raw, property, scope, element, data, &size)
    }

    func initialize(_ unit: NativeAudioUnitHandle) -> OSStatus {
        guard let raw = unit.raw else { return -50 }
        return AudioUnitInitialize(raw)
    }

    func start(_ unit: NativeAudioUnitHandle) -> OSStatus {
        guard let raw = unit.raw else { return -50 }
        return AudioOutputUnitStart(raw)
    }

    func stop(_ unit: NativeAudioUnitHandle) -> OSStatus {
        guard let raw = unit.raw else { return -50 }
        return AudioOutputUnitStop(raw)
    }

    func uninitialize(_ unit: NativeAudioUnitHandle) -> OSStatus {
        guard let raw = unit.raw else { return -50 }
        return AudioUnitUninitialize(raw)
    }

    func dispose(_ unit: NativeAudioUnitHandle) -> OSStatus {
        guard let raw = unit.raw else { return noErr }
        return AudioComponentInstanceDispose(raw)
    }

    func render(
        _ unit: NativeAudioUnitHandle,
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        busNumber: UInt32,
        frames: UInt32,
        data: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        guard let raw = unit.raw else { return -50 }
        return AudioUnitRender(raw, actionFlags, timeStamp, busNumber, frames, data)
    }

    func addPropertyListenerBlock(
        objectID: AudioObjectID,
        address: UnsafeMutablePointer<AudioObjectPropertyAddress>,
        queue: DispatchQueue,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        AudioObjectAddPropertyListenerBlock(objectID, address, queue, listener)
    }

    func removePropertyListenerBlock(
        objectID: AudioObjectID,
        address: UnsafeMutablePointer<AudioObjectPropertyAddress>,
        queue: DispatchQueue,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        AudioObjectRemovePropertyListenerBlock(objectID, address, queue, listener)
    }
}

private final class AudioRouteListenerContext: @unchecked Sendable {
    private let state = Atomic<UInt64>(0)
    private let queue = DispatchQueue(label: "com.nuvi.audio.route-control")
    private let handler: @Sendable () -> Void

    private static let deactivatedBit: UInt64 = 1 << 63
    private static let callbackCountMask: UInt64 = deactivatedBit - 1

    init(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }

    var dispatchQueue: DispatchQueue { queue }

    /// The block captures this context strongly. CoreAudio copies and retains
    /// the block until the matching block-removal call succeeds, so a failed
    /// removal cannot leave the native callback holding a dangling pointer.
    func makeListener() -> AudioObjectPropertyListenerBlock {
        { [self] numberAddresses, addresses in
            _ = numberAddresses
            _ = addresses
            guard self.beginListenerCallback() else { return }
            defer { self.endListenerCallback() }
            self.enqueue()
        }
    }

    func beginListenerCallback() -> Bool {
        while true {
            let current = state.load(ordering: .acquiring)
            guard current & Self.deactivatedBit == 0 else { return false }
            let count = current & Self.callbackCountMask
            guard count < Self.callbackCountMask else { return false }
            let result = state.compareExchange(
                expected: current,
                desired: current &+ 1,
                ordering: .acquiringAndReleasing
            )
            if result.exchanged { return true }
        }
    }

    func endListenerCallback() {
        state.wrappingSubtract(1, ordering: .releasing)
    }

    func enqueue() {
        guard state.load(ordering: .acquiring) & Self.deactivatedBit == 0 else { return }
        queue.async { [weak self] in
            guard let self,
                  self.state.load(ordering: .acquiring) & Self.deactivatedBit == 0 else { return }
            self.handler()
        }
    }

    func deactivate() {
        while true {
            let current = state.load(ordering: .acquiring)
            if current & Self.deactivatedBit != 0 { break }
            let result = state.compareExchange(
                expected: current,
                desired: current | Self.deactivatedBit,
                ordering: .acquiringAndReleasing
            )
            if result.exchanged { break }
        }
    }

    func waitForListenerCallbacks() {
        while state.load(ordering: .acquiring) & Self.callbackCountMask != 0 {
            sched_yield()
        }
    }
}

private struct AudioPropertyListenerTarget {
    let objectID: AudioObjectID
    let address: AudioObjectPropertyAddress
}

private struct AudioPropertyListenerRegistration {
    let objectID: AudioObjectID
    let address: AudioObjectPropertyAddress
    let queue: DispatchQueue
    let listener: AudioObjectPropertyListenerBlock
}

internal final class NativeAudioUnitLifecycle: AudioUnitLifecycle, @unchecked Sendable {
    let handle: NativeAudioUnitHandle
    private let operations: AudioUnitNativeOperations
    private let controlLock = NSRecursiveLock()
    private let renderEnabled = Atomic<Bool>(true)
    private var routeContext: AudioRouteListenerContext?
    private var listenerRegistrations: [AudioPropertyListenerRegistration] = []
    private var failedListenerRemovals: [AudioPropertyListenerRegistration] = []
    private var lifecycleState = LifecycleState.configured
    private var stopStatus: OSStatus?
    private var uninitializeStatus: OSStatus?
    private var disposeStatus: OSStatus?
    private var quarantineRetryAttempts = 0

    private enum LifecycleState {
        case configured
        case initialized
        case running
        case stopped
        case uninitialized
        case disposePending
        case disposed
    }

    private static let lifecycleClosedStatus: OSStatus = OSStatus(paramErr)
    private static let maxQuarantineRetries = 3

    var unit: AudioUnit? { handle.raw }

    init(handle: NativeAudioUnitHandle, operations: AudioUnitNativeOperations) {
        self.handle = handle
        self.operations = operations
    }

    var cleanupStatus: AudioUnitCleanupStatus {
        withControlLock {
            AudioUnitCleanupStatus(
                stop: stopStatus,
                uninitialize: uninitializeStatus,
                dispose: disposeStatus,
                failedListenerRemovals: failedListenerRemovals.count
            )
        }
    }

    var hasPendingCleanup: Bool {
        withControlLock { lifecycleState != .disposed || !failedListenerRemovals.isEmpty }
    }

    func withControlLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        controlLock.lock()
        defer { controlLock.unlock() }
        return try body()
    }

    func initializeUnit() -> OSStatus {
        withControlLock {
            switch lifecycleState {
            case .configured:
                let status = operations.initialize(handle)
                if status == noErr { lifecycleState = .initialized }
                return status
            case .initialized, .running:
                return noErr
            case .stopped, .uninitialized, .disposePending, .disposed:
                return Self.lifecycleClosedStatus
            }
        }
    }

    func startIO() -> OSStatus {
        withControlLock {
            switch lifecycleState {
            case .initialized:
                let status = operations.start(handle)
                if status == noErr { lifecycleState = .running }
                return status
            case .running:
                return noErr
            case .configured, .stopped, .uninitialized, .disposePending, .disposed:
                return Self.lifecycleClosedStatus
            }
        }
    }

    func render(
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        busNumber: UInt32,
        frames: UInt32,
        data: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        guard renderEnabled.load(ordering: .acquiring) else { return Self.lifecycleClosedStatus }
        return operations.render(
            handle,
            actionFlags: actionFlags,
            timeStamp: timeStamp,
            busNumber: busNumber,
            frames: frames,
            data: data
        )
    }

    func installRouteListeners(
        inputDevice: AudioDeviceID,
        outputDevice: AudioDeviceID,
        onRouteChange: @escaping @Sendable () -> Void
    ) throws {
        try withControlLock {
            retryFailedListenerRemovalsLocked()
            guard failedListenerRemovals.isEmpty else {
                throw AudioCaptureError.nativeDuckingUnavailable(
                    nativeDuckingUnavailableMessage("A previous audio route listener could not be removed")
                )
            }
            guard lifecycleState != .disposePending, lifecycleState != .disposed else {
                throw AudioCaptureError.nativeDuckingUnavailable(
                    nativeDuckingUnavailableMessage("The native capture lifecycle is already closed")
                )
            }
            guard routeContext == nil else { return }

            let context = AudioRouteListenerContext(handler: onRouteChange)
            let listener = context.makeListener()
            let registrations = makeRouteListenerRegistrations(
                inputDevice: inputDevice,
                outputDevice: outputDevice
            )

            for registration in registrations {
                let registration = AudioPropertyListenerRegistration(
                    objectID: registration.objectID,
                    address: registration.address,
                    queue: context.dispatchQueue,
                    listener: listener
                )
                var address = registration.address
                let status = operations.addPropertyListenerBlock(
                    objectID: registration.objectID,
                    address: &address,
                    queue: registration.queue,
                    listener: registration.listener
                )
                guard status == noErr else {
                    NSLog("Nuvi/audio: failed to add route listener (status \(status))")
                    removeRouteListenersLocked(context: context)
                    throw AudioCaptureError.nativeDuckingUnavailable(
                        nativeDuckingUnavailableMessage(
                            "Could not monitor an audio route change (status \(status))"
                        )
                    )
                }
                listenerRegistrations.append(registration)
            }
            routeContext = context
        }
    }

    func stop() {
        withControlLock { _ = stopLocked() }
    }

    func uninitialize() {
        withControlLock { _ = uninitializeLocked() }
    }

    func dispose() {
        withControlLock { _ = disposeLocked() }
    }

    func cleanup() {
        withControlLock {
            _ = stopLocked()
            _ = uninitializeLocked()
            _ = disposeLocked()
        }
    }

    func installCaptureCallback(for session: AudioCaptureSession) -> OSStatus {
        withControlLock {
            guard lifecycleState == .configured else { return Self.lifecycleClosedStatus }
            callbackOwner = session
            var callback = AURenderCallbackStruct(
                inputProc: captureRenderCallback,
                inputProcRefCon: Unmanaged.passUnretained(session).toOpaque()
            )
            let status = operations.setProperty(
                handle,
                property: kAudioOutputUnitProperty_SetInputCallback,
                scope: kAudioUnitScope_Global,
                element: 0,
                data: &callback,
                size: UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            )
            if status != noErr { callbackOwner = nil }
            return status
        }
    }

    private var callbackOwner: AudioCaptureSession?

    private func stopLocked() -> OSStatus {
        if lifecycleState == .disposed { return noErr }
        if stopStatus == noErr { return noErr }
        if lifecycleState == .uninitialized || lifecycleState == .disposePending {
            return stopStatus ?? Self.lifecycleClosedStatus
        }

        let status = operations.stop(handle)
        stopStatus = status
        if status == noErr {
            lifecycleState = .stopped
        } else {
            NSLog("Nuvi/audio: native stop failed (status \(status))")
        }
        return status
    }

    private func uninitializeLocked() -> OSStatus {
        if lifecycleState == .disposed { return noErr }
        if uninitializeStatus == noErr { return noErr }

        let status = operations.uninitialize(handle)
        uninitializeStatus = status
        if status == noErr {
            lifecycleState = .uninitialized
        } else {
            NSLog("Nuvi/audio: native uninitialize failed (status \(status))")
        }
        return status
    }

    private func disposeLocked() -> OSStatus {
        if lifecycleState == .disposed {
            retryFailedListenerRemovalsLocked()
            retainForCleanupIfNeededLocked()
            return disposeStatus ?? noErr
        }

        renderEnabled.store(false, ordering: .releasing)
        removeRouteListenersLocked()
        if disposeStatus == noErr { return noErr }

        let status = operations.dispose(handle)
        disposeStatus = status
        if status == noErr {
            lifecycleState = .disposed
            // The audio unit is no longer able to call the input callback. A
            // failed listener removal is independent and retains only its
            // inactive block/context registration below.
            callbackOwner = nil
        } else {
            lifecycleState = .disposePending
            NSLog("Nuvi/audio: native dispose failed (status \(status)); retaining cleanup ownership")
        }
        retainForCleanupIfNeededLocked()
        return status
    }

    private func retryFailedListenerRemovalsLocked() {
        guard !failedListenerRemovals.isEmpty else { return }
        var remaining: [AudioPropertyListenerRegistration] = []
        remaining.reserveCapacity(failedListenerRemovals.count)
        for registration in failedListenerRemovals {
            var address = registration.address
            let status = operations.removePropertyListenerBlock(
                objectID: registration.objectID,
                address: &address,
                queue: registration.queue,
                listener: registration.listener
            )
            if status == noErr {
                continue
            }
            NSLog("Nuvi/audio: retrying route listener removal failed (status \(status))")
            remaining.append(registration)
        }
        failedListenerRemovals = remaining
    }

    private func removeRouteListenersLocked(context: AudioRouteListenerContext? = nil) {
        let context = context ?? routeContext
        guard let context else { return }
        // Deactivate before asking CoreAudio to remove the blocks. Any block
        // already retained by CoreAudio can still run, but it can only enqueue
        // a no-op after this point.
        context.deactivate()
        let registrations = listenerRegistrations
        listenerRegistrations.removeAll()
        for registration in registrations {
            var address = registration.address
            let status = operations.removePropertyListenerBlock(
                objectID: registration.objectID,
                address: &address,
                queue: registration.queue,
                listener: registration.listener
            )
            guard status == noErr else {
                NSLog("Nuvi/audio: route listener removal failed (status \(status))")
                failedListenerRemovals.append(registration)
                continue
            }
        }
        context.waitForListenerCallbacks()
        if routeContext === context {
            routeContext = nil
        }
        if !failedListenerRemovals.isEmpty {
            retainForCleanupIfNeededLocked()
        }
    }

    private func retainForCleanupIfNeededLocked() {
        guard lifecycleState != .disposed || !failedListenerRemovals.isEmpty else { return }
        NativeAudioUnitFailureQuarantine.shared.retain(self)
    }

    var isFullyReleased: Bool {
        withControlLock {
            lifecycleState == .disposed && failedListenerRemovals.isEmpty
        }
    }

    func retryCleanupFromQuarantine() {
        withControlLock {
            guard !isFullyReleased else { return }
            guard quarantineRetryAttempts < Self.maxQuarantineRetries else {
                NSLog("Nuvi/audio: cleanup retry budget exhausted; retaining native resource safely")
                return
            }
            quarantineRetryAttempts += 1
            if let stopStatus, stopStatus != noErr, lifecycleState != .uninitialized, lifecycleState != .disposePending {
                _ = stopLocked()
            }
            if let uninitializeStatus, uninitializeStatus != noErr {
                _ = uninitializeLocked()
            }
            _ = disposeLocked()
        }
    }
}

/// Bounded, control-path-only ownership for resources whose native teardown
/// returned an error. No timer or realtime callback retries this list. If a
/// native block removal remains unsupported, its block/context stays inactive
/// and retained by CoreAudio rather than being released behind its back.
internal final class NativeAudioUnitFailureQuarantine: @unchecked Sendable {
    static let shared = NativeAudioUnitFailureQuarantine()

    private struct Entry {
        let lifecycle: NativeAudioUnitLifecycle
    }

    private let lock = NSRecursiveLock()
    private var entries: [Entry] = []
    private var reservations = 0
    private let capacity = 16

    func retryAll() {
        lock.lock()
        let current = entries.map(\.lifecycle)
        lock.unlock()

        for lifecycle in current {
            lifecycle.retryCleanupFromQuarantine()
        }

        lock.lock()
        entries.removeAll { $0.lifecycle.isFullyReleased }
        lock.unlock()
    }

    func acquireCaptureSlot() -> Bool {
        retryAll()
        lock.lock()
        defer { lock.unlock() }
        guard entries.count + reservations < capacity else { return false }
        reservations += 1
        return true
    }

    func releaseCaptureSlot() {
        lock.lock()
        reservations = max(0, reservations - 1)
        lock.unlock()
    }

    func retain(_ lifecycle: NativeAudioUnitLifecycle) {
        lock.lock()
        defer { lock.unlock() }
        guard !entries.contains(where: { $0.lifecycle === lifecycle }) else { return }
        guard entries.count < capacity else {
            NSLog("Nuvi/audio: cleanup quarantine capacity exhausted; retaining lifecycle through native ownership")
            return
        }
        entries.append(Entry(lifecycle: lifecycle))
    }

    static func retryAllForTesting() {
        shared.retryAll()
    }
}

private func makeRouteListenerRegistrations(
    inputDevice: AudioDeviceID,
    outputDevice: AudioDeviceID
) -> [AudioPropertyListenerTarget] {
    let systemObject = AudioObjectID(kAudioObjectSystemObject)
    let defaultOutput = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let alive = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsAlive,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let nominalRate = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var registrations = [AudioPropertyListenerTarget(
        objectID: systemObject,
        address: defaultOutput
    )]
    for device in [inputDevice, outputDevice] where device != AudioDeviceID(kAudioObjectUnknown) {
        for address in [alive, nominalRate]
        where !registrations.contains(where: { $0.objectID == device && sameAddress($0.address, address) }) {
            registrations.append(AudioPropertyListenerTarget(objectID: device, address: address))
        }
    }
    return registrations
}

private func sameAddress(_ lhs: AudioObjectPropertyAddress, _ rhs: AudioObjectPropertyAddress) -> Bool {
    lhs.mSelector == rhs.mSelector
        && lhs.mScope == rhs.mScope
        && lhs.mElement == rhs.mElement
}

private final class NativeAudioCaptureBackend: AudioCaptureBackend, @unchecked Sendable {
    let kind: AudioCaptureBackendKind
    let lifecycle: AudioUnitLifecycle
    let captureFormat: AVAudioFormat
    let captureChannelCount: Int
    let maximumFramesPerSlice: UInt32
    let usesBluetoothInput: Bool
    private(set) var diagnostics: AudioCaptureDiagnostics

    private let nativeLifecycle: NativeAudioUnitLifecycle
    private let operations: AudioUnitNativeOperations
    private let inputDevice: AudioDeviceID
    private let inputDeviceElement: AudioUnitElement
    private let outputDevice: AudioDeviceID?
    private let expectedInputClientFormat: AudioStreamBasicDescription
    private let expectedOutputClientFormat: AudioStreamBasicDescription?
    private let setupFailure: (String) -> AudioCaptureError

    init(
        kind: AudioCaptureBackendKind,
        lifecycle: NativeAudioUnitLifecycle,
        operations: AudioUnitNativeOperations,
        captureFormat: AVAudioFormat,
        captureChannelCount: Int,
        maximumFramesPerSlice: UInt32,
        usesBluetoothInput: Bool,
        inputDevice: AudioDeviceID,
        inputDeviceElement: AudioUnitElement,
        outputDevice: AudioDeviceID?,
        expectedInputClientFormat: AudioStreamBasicDescription,
        expectedOutputClientFormat: AudioStreamBasicDescription?,
        setupFailure: @escaping (String) -> AudioCaptureError
    ) {
        self.kind = kind
        self.lifecycle = lifecycle
        self.nativeLifecycle = lifecycle
        self.operations = operations
        self.captureFormat = captureFormat
        self.captureChannelCount = captureChannelCount
        self.maximumFramesPerSlice = maximumFramesPerSlice
        self.usesBluetoothInput = usesBluetoothInput
        self.inputDevice = inputDevice
        self.inputDeviceElement = inputDeviceElement
        self.outputDevice = outputDevice
        self.expectedInputClientFormat = expectedInputClientFormat
        self.expectedOutputClientFormat = expectedOutputClientFormat
        self.diagnostics = AudioCaptureDiagnostics(
            requestedBackend: kind,
            effectiveBackend: nil,
            selectedInputUID: nil,
            selectedInputID: inputDevice,
            boundInputID: inputDevice,
            boundOutputID: outputDevice,
            inputClientFormat: AudioFormatSnapshot(expectedInputClientFormat),
            outputClientFormat: expectedOutputClientFormat.map(AudioFormatSnapshot.init),
            maximumFramesPerSlice: maximumFramesPerSlice,
            cleanupComplete: false
        )
        self.setupFailure = setupFailure
    }

    func installCallbacks(for session: AudioCaptureSession) throws {
        try nativeLifecycle.withControlLock {
            let status = nativeLifecycle.installCaptureCallback(for: session)
            guard status == noErr else {
                throw setupFailure("Could not install the microphone callback (status \(status))")
            }

            if kind == .voiceProcessingIO, let outputDevice {
                try nativeLifecycle.installRouteListeners(
                    inputDevice: inputDevice,
                    outputDevice: outputDevice,
                    onRouteChange: { [weak session] in
                        session?.cleanup()
                    }
                )
            }
        }
    }

    func start() throws {
        try nativeLifecycle.withControlLock {
            let initializationStatus = nativeLifecycle.initializeUnit()
            guard initializationStatus == noErr else {
                throw setupFailure("Could not initialize the capture unit (status \(initializationStatus))")
            }

            try verifyCurrentDevices(stage: "initialization")
            if kind == .voiceProcessingIO {
                try verifyEffectiveFormats(stage: "initialization")
            }

            let startStatus = nativeLifecycle.startIO()
            guard startStatus == noErr else {
                throw setupFailure("Could not start the capture unit (status \(startStatus))")
            }

            try verifyCurrentDevices(stage: "start")
            if kind == .voiceProcessingIO {
                try verifyEffectiveFormats(stage: "start")
            }
            diagnostics = diagnostics.with(effectiveBackend: kind)
        }
    }

    func cleanup() {
        nativeLifecycle.withControlLock {
            nativeLifecycle.cleanup()
            diagnostics = diagnostics.with(
                cleanupComplete: nativeLifecycle.cleanupStatus.isComplete
            )
        }
    }

    private func verifyCurrentDevices(stage: String) throws {
        let actualInput = try readCurrentDevice(element: inputDeviceElement)
        guard actualInput == inputDevice else {
            throw setupFailure(
                "The microphone route changed during \(stage) (requested \(inputDevice), got \(actualInput))"
            )
        }

        guard let outputDevice else { return }
        let actualOutput = try readCurrentDevice(element: 0)
        guard actualOutput == outputDevice else {
            throw setupFailure(
                "The output route changed during \(stage) (requested \(outputDevice), got \(actualOutput))"
            )
        }
    }

    private func readCurrentDevice(element: AudioUnitElement) throws -> AudioDeviceID {
        var value: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = operations.getProperty(
            nativeLifecycle.handle,
            property: kAudioOutputUnitProperty_CurrentDevice,
            scope: kAudioUnitScope_Global,
            element: element,
            data: &value,
            size: &size
        )
        guard status == noErr, size >= UInt32(MemoryLayout<AudioDeviceID>.size) else {
            throw setupFailure(
                "Could not read back the \(element == 1 ? "microphone" : "output") route (status \(status))"
            )
        }
        return value
    }

    private func verifyEffectiveFormats(stage: String) throws {
        let input = try readFormat(
            scope: kAudioUnitScope_Output,
            element: 1,
            label: "microphone client",
            stage: stage
        )
        guard formatsMatch(input, expectedInputClientFormat) else {
            throw setupFailure("The microphone client format was coerced during \(stage)")
        }

        var outputSnapshot: AudioFormatSnapshot?
        if let expectedOutputClientFormat {
            let output = try readFormat(
                scope: kAudioUnitScope_Input,
                element: 0,
                label: "output client",
                stage: stage
            )
            guard formatsMatch(output, expectedOutputClientFormat) else {
                throw setupFailure("The output client format was coerced during \(stage)")
            }
            outputSnapshot = AudioFormatSnapshot(output)
        }

        let effectiveMaximum = try readMaximumFrames(stage: stage)
        guard effectiveMaximum > 0, effectiveMaximum <= maximumFramesPerSlice else {
            throw setupFailure(
                "The native maximum frame capacity changed during \(stage) " +
                "(effective \(effectiveMaximum), allocated \(maximumFramesPerSlice))"
            )
        }
        diagnostics = diagnostics.withEffectiveFormats(
            inputClientFormat: AudioFormatSnapshot(input),
            outputClientFormat: outputSnapshot,
            maximumFramesPerSlice: effectiveMaximum
        )
    }

    private func readFormat(
        scope: AudioUnitScope,
        element: AudioUnitElement,
        label: String,
        stage: String
    ) throws -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = operations.getProperty(
            nativeLifecycle.handle,
            property: kAudioUnitProperty_StreamFormat,
            scope: scope,
            element: element,
            data: &format,
            size: &size
        )
        guard status == noErr, size >= UInt32(MemoryLayout<AudioStreamBasicDescription>.size) else {
            throw setupFailure("Could not read the effective \(label) format during \(stage) (status \(status))")
        }
        return format
    }

    private func readMaximumFrames(stage: String) throws -> UInt32 {
        var maximumFrames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = operations.getProperty(
            nativeLifecycle.handle,
            property: kAudioUnitProperty_MaximumFramesPerSlice,
            scope: kAudioUnitScope_Global,
            element: 0,
            data: &maximumFrames,
            size: &size
        )
        guard status == noErr, size >= UInt32(MemoryLayout<UInt32>.size) else {
            throw setupFailure("Could not read the effective maximum frame capacity during \(stage) (status \(status))")
        }
        return maximumFrames
    }

    private func formatsMatch(
        _ lhs: AudioStreamBasicDescription,
        _ rhs: AudioStreamBasicDescription
    ) -> Bool {
        lhs.mSampleRate == rhs.mSampleRate
            && lhs.mFormatID == rhs.mFormatID
            && lhs.mFormatFlags == rhs.mFormatFlags
            && lhs.mBytesPerPacket == rhs.mBytesPerPacket
            && lhs.mFramesPerPacket == rhs.mFramesPerPacket
            && lhs.mBytesPerFrame == rhs.mBytesPerFrame
            && lhs.mChannelsPerFrame == rhs.mChannelsPerFrame
            && lhs.mBitsPerChannel == rhs.mBitsPerChannel
    }
}

internal final class NativeAudioCaptureBackendFactory: AudioCaptureBackendFactory, @unchecked Sendable {
    private let operations: AudioUnitNativeOperations
    private let devices: AudioDeviceProvider

    init(
        operations: AudioUnitNativeOperations = SystemAudioUnitNativeOperations.shared,
        devices: AudioDeviceProvider = SystemAudioDeviceProvider()
    ) {
        self.operations = operations
        self.devices = devices
    }

    func makeBackend(
        configuration: AudioCaptureConfiguration,
        inputDevice: AudioDeviceID
    ) throws -> AudioCaptureBackend {
        guard NativeAudioUnitFailureQuarantine.shared.acquireCaptureSlot() else {
            let reason = "Native audio cleanup capacity is temporarily exhausted"
            throw configuration.duckOtherAudio
                ? nativeDuckingFailure(reason)
                : halFailure(reason)
        }
        defer { NativeAudioUnitFailureQuarantine.shared.releaseCaptureSlot() }

        return configuration.duckOtherAudio
            ? try makeVoiceProcessingBackend(inputDevice: inputDevice)
            : try makeHALBackend(inputDevice: inputDevice)
    }

    private func makeHALBackend(inputDevice: AudioDeviceID) throws -> AudioCaptureBackend {
        var lifecycle: NativeAudioUnitLifecycle?
        do {
            let handle = try operations.makeUnit(componentSubType: UInt32(kAudioUnitSubType_HALOutput))
            let liveLifecycle = NativeAudioUnitLifecycle(handle: handle, operations: operations)
            lifecycle = liveLifecycle

            guard inputDevice != AudioDeviceID(kAudioObjectUnknown) else {
                throw AudioCaptureError.microphoneUnavailable("No input device")
            }
            try setIO(liveLifecycle.handle, property: kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Input, element: 1, value: 1, failure: halFailure)
            try setIO(liveLifecycle.handle, property: kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Output, element: 0, value: 0, failure: halFailure)
            try setCurrentDevice(liveLifecycle.handle, inputDevice: inputDevice, element: 0, failure: halFailure)

            let hardware = try readFormat(
                liveLifecycle.handle,
                scope: kAudioUnitScope_Input,
                element: 1,
                failure: halFailure
            )
            guard hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0 else {
                throw halFailure("The input device reported an invalid audio format")
            }
            var client = makeClientFormat(
                sampleRate: hardware.mSampleRate,
                channels: hardware.mChannelsPerFrame
            )
            try setFormat(
                liveLifecycle.handle,
                scope: kAudioUnitScope_Output,
                element: 1,
                format: &client,
                failure: halFailure
            )
            guard let captureFormat = AVAudioFormat(streamDescription: &client) else {
                throw halFailure("Could not create the microphone PCM format")
            }
            let maximumFrames = try readMaximumFrames(liveLifecycle.handle, failure: halFailure)
            return NativeAudioCaptureBackend(
                kind: .hal,
                lifecycle: liveLifecycle,
                operations: operations,
                captureFormat: captureFormat,
                captureChannelCount: Int(hardware.mChannelsPerFrame),
                maximumFramesPerSlice: maximumFrames,
                usesBluetoothInput: devices.isBluetoothInputDevice(inputDevice),
                inputDevice: inputDevice,
                inputDeviceElement: 0,
                outputDevice: nil,
                expectedInputClientFormat: client,
                expectedOutputClientFormat: nil,
                setupFailure: halFailure
            )
        } catch let error as AudioCaptureError {
            lifecycle?.cleanup()
            throw error
        } catch {
            lifecycle?.cleanup()
            throw halFailure(String(describing: error))
        }
    }

    private func makeVoiceProcessingBackend(inputDevice: AudioDeviceID) throws -> AudioCaptureBackend {
        var lifecycle: NativeAudioUnitLifecycle?
        do {
            let handle = try operations.makeUnit(componentSubType: UInt32(kAudioUnitSubType_VoiceProcessingIO))
            let liveLifecycle = NativeAudioUnitLifecycle(handle: handle, operations: operations)
            lifecycle = liveLifecycle

            guard inputDevice != AudioDeviceID(kAudioObjectUnknown) else {
                throw nativeDuckingFailure("No supported input device is available")
            }
            guard let outputDevice = devices.defaultOutputDeviceID(),
                  outputDevice != AudioDeviceID(kAudioObjectUnknown) else {
                throw nativeDuckingFailure("No current output device is available")
            }

            // VPIO is intentionally full duplex: bus 1 captures the selected
            // microphone while bus 0 receives the zero-filled output callback.
            try setIO(liveLifecycle.handle, property: kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Input, element: 1, value: 1, failure: nativeDuckingFailure)
            try setIO(liveLifecycle.handle, property: kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Output, element: 0, value: 1, failure: nativeDuckingFailure)
            try setCurrentDevice(liveLifecycle.handle, inputDevice: inputDevice, element: 1, failure: nativeDuckingFailure)
            try setCurrentDevice(liveLifecycle.handle, inputDevice: outputDevice, element: 0, failure: nativeDuckingFailure)
            try verifyCurrentDevice(
                liveLifecycle.handle,
                requested: inputDevice,
                element: 1,
                stage: "route setup"
            )
            try verifyCurrentDevice(
                liveLifecycle.handle,
                requested: outputDevice,
                element: 0,
                stage: "route setup"
            )

            try configureDucking(on: liveLifecycle.handle)
            try disableVoiceProcessingBypass(on: liveLifecycle.handle)
            try disableVoiceProcessingAGC(on: liveLifecycle.handle)

            let inputHardware = try readFormat(
                liveLifecycle.handle,
                scope: kAudioUnitScope_Input,
                element: 1,
                failure: nativeDuckingFailure
            )
            guard inputHardware.mSampleRate > 0, inputHardware.mChannelsPerFrame > 0 else {
                throw nativeDuckingFailure("The microphone reported an invalid audio format")
            }

            // VPIO routes have reported stereo input formats that are rejected
            // when used as the client format. Capture one mono non-interleaved
            // Float32 channel at the input hardware rate instead.
            var inputClient = makeClientFormat(sampleRate: inputHardware.mSampleRate, channels: 1)
            try setFormat(
                liveLifecycle.handle,
                scope: kAudioUnitScope_Output,
                element: 1,
                format: &inputClient,
                failure: nativeDuckingFailure
            )
            guard let captureFormat = AVAudioFormat(streamDescription: &inputClient) else {
                throw nativeDuckingFailure("Could not create the VPIO microphone PCM format")
            }

            // Output is configured independently from input. Preserve the
            // current output device's rate and channel count for the client
            // callback, while still supplying silence to the hardware.
            let outputHardware = try readFormat(
                liveLifecycle.handle,
                scope: kAudioUnitScope_Output,
                element: 0,
                failure: nativeDuckingFailure
            )
            guard outputHardware.mSampleRate > 0, outputHardware.mChannelsPerFrame > 0 else {
                throw nativeDuckingFailure("The output device reported an invalid audio format")
            }
            var outputClient = makeClientFormat(
                sampleRate: outputHardware.mSampleRate,
                channels: outputHardware.mChannelsPerFrame
            )
            try setFormat(
                liveLifecycle.handle,
                scope: kAudioUnitScope_Input,
                element: 0,
                format: &outputClient,
                failure: nativeDuckingFailure
            )
            try installSilenceCallback(on: liveLifecycle.handle)

            let maximumFrames = try readMaximumFrames(
                liveLifecycle.handle,
                failure: nativeDuckingFailure
            )
            return NativeAudioCaptureBackend(
                kind: .voiceProcessingIO,
                lifecycle: liveLifecycle,
                operations: operations,
                captureFormat: captureFormat,
                captureChannelCount: 1,
                maximumFramesPerSlice: maximumFrames,
                usesBluetoothInput: devices.isBluetoothInputDevice(inputDevice),
                inputDevice: inputDevice,
                inputDeviceElement: 1,
                outputDevice: outputDevice,
                expectedInputClientFormat: inputClient,
                expectedOutputClientFormat: outputClient,
                setupFailure: nativeDuckingFailure
            )
        } catch let error as AudioCaptureError {
            lifecycle?.cleanup()
            if case .nativeDuckingUnavailable = error {
                throw error
            }
            throw nativeDuckingFailure(String(describing: error))
        } catch {
            lifecycle?.cleanup()
            throw nativeDuckingFailure(String(describing: error))
        }
    }

    private func setIO(
        _ unit: NativeAudioUnitHandle,
        property: AudioUnitPropertyID,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        value: UInt32,
        failure: (String) -> AudioCaptureError
    ) throws {
        var value = value
        try set(
            unit,
            property: property,
            scope: scope,
            element: element,
            data: &value,
            size: UInt32(MemoryLayout<UInt32>.size),
            failure: failure
        )
    }

    private func setCurrentDevice(
        _ unit: NativeAudioUnitHandle,
        inputDevice: AudioDeviceID,
        element: AudioUnitElement,
        failure: (String) -> AudioCaptureError
    ) throws {
        var device = inputDevice
        try set(
            unit,
            property: kAudioOutputUnitProperty_CurrentDevice,
            scope: kAudioUnitScope_Global,
            element: element,
            data: &device,
            size: UInt32(MemoryLayout<AudioDeviceID>.size),
            failure: failure
        )
    }

    private func configureDucking(on unit: NativeAudioUnitHandle) throws {
        var configuration = AUVoiceIOOtherAudioDuckingConfiguration(
            mEnableAdvancedDucking: false,
            mDuckingLevel: .mid
        )
        try set(
            unit,
            property: kAUVoiceIOProperty_OtherAudioDuckingConfiguration,
            scope: kAudioUnitScope_Global,
            element: 0,
            data: &configuration,
            size: UInt32(MemoryLayout<AUVoiceIOOtherAudioDuckingConfiguration>.size),
            failure: nativeDuckingFailure
        )
    }

    private func disableVoiceProcessingAGC(on unit: NativeAudioUnitHandle) throws {
        var disabled: UInt32 = 0
        try set(
            unit,
            property: kAUVoiceIOProperty_VoiceProcessingEnableAGC,
            scope: kAudioUnitScope_Global,
            element: 0,
            data: &disabled,
            size: UInt32(MemoryLayout<UInt32>.size),
            failure: nativeDuckingFailure
        )

        var readback: UInt32 = 1
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = operations.getProperty(
            unit,
            property: kAUVoiceIOProperty_VoiceProcessingEnableAGC,
            scope: kAudioUnitScope_Global,
            element: 0,
            data: &readback,
            size: &size
        )
        guard status == noErr, size >= UInt32(MemoryLayout<UInt32>.size), readback == 0 else {
            throw nativeDuckingFailure("Voice-processing AGC could not be disabled (status \(status))")
        }
    }

    private func disableVoiceProcessingBypass(on unit: NativeAudioUnitHandle) throws {
        var disabled: UInt32 = 0
        try set(
            unit,
            property: kAUVoiceIOProperty_BypassVoiceProcessing,
            scope: kAudioUnitScope_Global,
            element: 0,
            data: &disabled,
            size: UInt32(MemoryLayout<UInt32>.size),
            failure: nativeDuckingFailure
        )

        var readback: UInt32 = 1
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = operations.getProperty(
            unit,
            property: kAUVoiceIOProperty_BypassVoiceProcessing,
            scope: kAudioUnitScope_Global,
            element: 0,
            data: &readback,
            size: &size
        )
        guard status == noErr, size >= UInt32(MemoryLayout<UInt32>.size), readback == 0 else {
            throw nativeDuckingFailure("Voice-processing bypass could not be disabled (status \(status))")
        }
    }

    private func installSilenceCallback(on unit: NativeAudioUnitHandle) throws {
        var callback = AURenderCallbackStruct(
            inputProc: silenceRenderCallback,
            inputProcRefCon: nil
        )
        try set(
            unit,
            property: kAudioUnitProperty_SetRenderCallback,
            scope: kAudioUnitScope_Input,
            element: 0,
            data: &callback,
            size: UInt32(MemoryLayout<AURenderCallbackStruct>.size),
            failure: nativeDuckingFailure
        )
    }

    private func verifyCurrentDevice(
        _ unit: NativeAudioUnitHandle,
        requested: AudioDeviceID,
        element: AudioUnitElement,
        stage: String
    ) throws {
        var actual = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = operations.getProperty(
            unit,
            property: kAudioOutputUnitProperty_CurrentDevice,
            scope: kAudioUnitScope_Global,
            element: element,
            data: &actual,
            size: &size
        )
        guard status == noErr, size >= UInt32(MemoryLayout<AudioDeviceID>.size) else {
            throw nativeDuckingFailure(
                "Could not read back the \(element == 1 ? "microphone" : "output") route during \(stage) (status \(status))"
            )
        }
        guard actual == requested else {
            throw nativeDuckingFailure(
                "The \(element == 1 ? "microphone" : "output") route readback mismatched during \(stage) (requested \(requested), got \(actual))"
            )
        }
    }

    private func set(
        _ unit: NativeAudioUnitHandle,
        property: AudioUnitPropertyID,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        data: UnsafeMutableRawPointer,
        size: UInt32,
        failure: (String) -> AudioCaptureError
    ) throws {
        let status = operations.setProperty(
            unit,
            property: property,
            scope: scope,
            element: element,
            data: data,
            size: size
        )
        guard status == noErr else {
            throw failure("Audio unit property \(property) failed (status \(status))")
        }
    }

    private func readFormat(
        _ unit: NativeAudioUnitHandle,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        failure: (String) -> AudioCaptureError
    ) throws -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = operations.getProperty(
            unit,
            property: kAudioUnitProperty_StreamFormat,
            scope: scope,
            element: element,
            data: &format,
            size: &size
        )
        guard status == noErr, size >= UInt32(MemoryLayout<AudioStreamBasicDescription>.size) else {
            throw failure("Could not read the audio format (status \(status))")
        }
        return format
    }

    private func setFormat(
        _ unit: NativeAudioUnitHandle,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        format: UnsafeMutablePointer<AudioStreamBasicDescription>,
        failure: (String) -> AudioCaptureError
    ) throws {
        try set(
            unit,
            property: kAudioUnitProperty_StreamFormat,
            scope: scope,
            element: element,
            data: format,
            size: UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            failure: failure
        )
    }

    private func readMaximumFrames(
        _ unit: NativeAudioUnitHandle,
        failure: (String) -> AudioCaptureError
    ) throws -> UInt32 {
        var maximumFrames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = operations.getProperty(
            unit,
            property: kAudioUnitProperty_MaximumFramesPerSlice,
            scope: kAudioUnitScope_Global,
            element: 0,
            data: &maximumFrames,
            size: &size
        )
        guard status == noErr, size >= UInt32(MemoryLayout<UInt32>.size), maximumFrames > 0 else {
            throw failure("Could not read maximum frames per slice (status \(status))")
        }
        return maximumFrames
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

    private func halFailure(_ reason: String) -> AudioCaptureError {
        .microphoneUnavailable(reason)
    }

    private func nativeDuckingFailure(_ reason: String) -> AudioCaptureError {
        .nativeDuckingUnavailable(nativeDuckingUnavailableMessage(reason))
    }
}
