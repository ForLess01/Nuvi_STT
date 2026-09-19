import XCTest
import AVFoundation
import AudioToolbox
import CoreAudio
@testable import Nuvi

final class AudioCaptureBackendTests: XCTestCase {
    func testDisabledConfigurationSelectsHALWithoutVoiceProcessingSetup() throws {
        let operations = RecordingNativeOperations()
        let devices = TestAudioDeviceProvider(outputDevice: 202)
        let factory = NativeAudioCaptureBackendFactory(operations: operations, devices: devices)

        let backend = try factory.makeBackend(
            configuration: AudioCaptureConfiguration(duckOtherAudio: false),
            inputDevice: 101
        )

        XCTAssertEqual(backend.kind, .hal)
        XCTAssertEqual(operations.createdSubtypes, [UInt32(kAudioUnitSubType_HALOutput)])
        XCTAssertFalse(operations.setCalls.contains { $0.property == kAUVoiceIOProperty_OtherAudioDuckingConfiguration })
        XCTAssertFalse(operations.setCalls.contains { $0.property == kAUVoiceIOProperty_VoiceProcessingEnableAGC })
        XCTAssertFalse(operations.setCalls.contains { $0.property == kAudioUnitProperty_SetRenderCallback })
        XCTAssertTrue(operations.addedListeners.isEmpty)

        backend.cleanup()
        XCTAssertEqual(operations.stopCount, 1)
        XCTAssertEqual(operations.uninitializeCount, 1)
        XCTAssertEqual(operations.disposeCount, 1)
    }

    func testHALStartRejectsInputRouteReadbackMismatchWithoutSubstitution() throws {
        let operations = RecordingNativeOperations()
        operations.readbackOverrides[0] = 999
        let factory = NativeAudioCaptureBackendFactory(
            operations: operations,
            devices: TestAudioDeviceProvider(outputDevice: 202)
        )
        let backend = try factory.makeBackend(
            configuration: AudioCaptureConfiguration(duckOtherAudio: false),
            inputDevice: 101
        )

        XCTAssertThrowsError(try backend.start()) { error in
            guard case let AudioCaptureError.microphoneUnavailable(reason) = error else {
                return XCTFail("Expected microphone failure, got \(error)")
            }
            XCTAssertTrue(reason.contains("microphone route"))
        }
        backend.cleanup()

        XCTAssertEqual(operations.createdSubtypes, [UInt32(kAudioUnitSubType_HALOutput)])
        XCTAssertEqual(operations.stopCount, 1)
        XCTAssertEqual(operations.uninitializeCount, 1)
        XCTAssertEqual(operations.disposeCount, 1)
    }

    func testEnabledConfigurationBuildsFullDuplexVPIOWithFixedDuckingAndSeparateFormats() throws {
        let operations = RecordingNativeOperations(
            inputHardware: makeFormat(sampleRate: 48_000, channels: 2),
            outputHardware: makeFormat(sampleRate: 44_100, channels: 2)
        )
        let devices = TestAudioDeviceProvider(outputDevice: 202)
        let factory = NativeAudioCaptureBackendFactory(operations: operations, devices: devices)

        let backend = try factory.makeBackend(
            configuration: AudioCaptureConfiguration(duckOtherAudio: true),
            inputDevice: 101
        )

        XCTAssertEqual(backend.kind, .voiceProcessingIO)
        XCTAssertEqual(operations.createdSubtypes, [UInt32(kAudioUnitSubType_VoiceProcessingIO)])
        XCTAssertEqual(operations.currentDeviceWrites[1], 101)
        XCTAssertEqual(operations.currentDeviceWrites[0], 202)
        XCTAssertEqual(devices.defaultOutputReadCount, 1)
        XCTAssertEqual(devices.defaultWriteCount, 0)

        let ducking = try XCTUnwrap(
            operations.setCalls.first { $0.property == kAUVoiceIOProperty_OtherAudioDuckingConfiguration }
        )
        XCTAssertEqual(ducking.scope, kAudioUnitScope_Global)
        XCTAssertEqual(ducking.element, 0)
        XCTAssertEqual(ducking.size, UInt32(MemoryLayout<AUVoiceIOOtherAudioDuckingConfiguration>.size))
        let configuration = ducking.bytes.withUnsafeBytes {
            $0.load(as: AUVoiceIOOtherAudioDuckingConfiguration.self)
        }
        XCTAssertEqual(withUnsafeBytes(of: configuration) { $0[0] }, 0)
        XCTAssertEqual(configuration.mDuckingLevel, .mid)

        let agc = try XCTUnwrap(
            operations.setCalls.first { $0.property == kAUVoiceIOProperty_VoiceProcessingEnableAGC }
        )
        XCTAssertEqual(agc.bytes.withUnsafeBytes { $0.load(as: UInt32.self) }, 0)

        let inputClient = try XCTUnwrap(
            operations.formatWrites.first {
                $0.scope == kAudioUnitScope_Output && $0.element == 1
            }
        )
        XCTAssertEqual(inputClient.format.mSampleRate, 48_000)
        XCTAssertEqual(inputClient.format.mChannelsPerFrame, 1)
        XCTAssertTrue(inputClient.format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0)
        XCTAssertTrue(inputClient.format.mFormatFlags & kAudioFormatFlagIsFloat != 0)

        let outputClient = try XCTUnwrap(
            operations.formatWrites.first {
                $0.scope == kAudioUnitScope_Input && $0.element == 0
            }
        )
        XCTAssertEqual(outputClient.format.mSampleRate, 44_100)
        XCTAssertEqual(outputClient.format.mChannelsPerFrame, 2)
        XCTAssertTrue(
            operations.setCalls.contains {
                $0.property == kAudioUnitProperty_SetRenderCallback
                    && $0.scope == kAudioUnitScope_Input
                    && $0.element == 0
            }
        )
        let bypass = try XCTUnwrap(
            operations.setCalls.first { $0.property == kAUVoiceIOProperty_BypassVoiceProcessing }
        )
        XCTAssertEqual(bypass.bytes.withUnsafeBytes { $0.load(as: UInt32.self) }, 0)
        XCTAssertFalse(operations.setCalls.contains { $0.property == kAUVoiceIOProperty_MuteOutput })

        try backend.start()
        XCTAssertEqual(backend.diagnostics.effectiveBackend, .voiceProcessingIO)
        XCTAssertEqual(backend.diagnostics.inputClientFormat?.channelsPerFrame, 1)
        XCTAssertEqual(backend.diagnostics.outputClientFormat?.sampleRate, 44_100)
        XCTAssertEqual(backend.diagnostics.maximumFramesPerSlice, 512)

        backend.cleanup()
    }

    func testVPIORouteReadbackMismatchFailsWithoutHALFallbackAndCleansUpOnce() {
        let operations = RecordingNativeOperations()
        operations.readbackOverrides[1] = 999
        let factory = NativeAudioCaptureBackendFactory(
            operations: operations,
            devices: TestAudioDeviceProvider(outputDevice: 202)
        )

        XCTAssertThrowsError(
            try factory.makeBackend(
                configuration: AudioCaptureConfiguration(duckOtherAudio: true),
                inputDevice: 101
            )
        ) { error in
            guard case let AudioCaptureError.nativeDuckingUnavailable(reason) = error else {
                return XCTFail("Expected native ducking failure, got \(error)")
            }
            XCTAssertTrue(reason.contains("mismatched"))
        }

        XCTAssertEqual(operations.createdSubtypes, [UInt32(kAudioUnitSubType_VoiceProcessingIO)])
        XCTAssertEqual(operations.stopCount, 1)
        XCTAssertEqual(operations.uninitializeCount, 1)
        XCTAssertEqual(operations.disposeCount, 1)
    }

    func testVPIODeviceBindingFailureIsExplicitAndDoesNotFallBackToHAL() {
        let operations = RecordingNativeOperations()
        operations.setStatus = -10879
        let factory = NativeAudioCaptureBackendFactory(
            operations: operations,
            devices: TestAudioDeviceProvider(outputDevice: 202)
        )

        XCTAssertThrowsError(
            try factory.makeBackend(
                configuration: AudioCaptureConfiguration(duckOtherAudio: true),
                inputDevice: 101
            )
        ) { error in
            guard case AudioCaptureError.nativeDuckingUnavailable = error else {
                return XCTFail("Expected native ducking failure, got \(error)")
            }
        }

        XCTAssertEqual(operations.createdSubtypes, [UInt32(kAudioUnitSubType_VoiceProcessingIO)])
        XCTAssertEqual(operations.stopCount, 1)
        XCTAssertEqual(operations.uninitializeCount, 1)
        XCTAssertEqual(operations.disposeCount, 1)
    }

    func testVPIOUnknownInputIDFailsWithoutSubstitution() {
        let operations = RecordingNativeOperations()
        let devices = TestAudioDeviceProvider(outputDevice: 202)
        let factory = NativeAudioCaptureBackendFactory(operations: operations, devices: devices)

        XCTAssertThrowsError(
            try factory.makeBackend(
                configuration: AudioCaptureConfiguration(duckOtherAudio: true),
                inputDevice: AudioDeviceID(kAudioObjectUnknown)
            )
        ) { error in
            guard case let AudioCaptureError.nativeDuckingUnavailable(reason) = error else {
                return XCTFail("Expected native ducking failure, got \(error)")
            }
            XCTAssertTrue(reason.contains("input device"))
        }

        XCTAssertEqual(operations.createdSubtypes, [UInt32(kAudioUnitSubType_VoiceProcessingIO)])
        XCTAssertTrue(operations.currentDeviceWrites.isEmpty)
        XCTAssertEqual(devices.defaultOutputReadCount, 0)
    }

    func testRouteListenerAddFailureUnwindsAlreadyRegisteredBlocksBeforeDispose() throws {
        let operations = RecordingNativeOperations()
        operations.failRouteListenerAddAfter = 2
        let factory = NativeAudioCaptureBackendFactory(
            operations: operations,
            devices: TestAudioDeviceProvider(outputDevice: 202)
        )
        let backend = try factory.makeBackend(
            configuration: AudioCaptureConfiguration(duckOtherAudio: true),
            inputDevice: 101
        )
        let (_, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        let session = AudioCaptureSession(
            lifecycle: backend.lifecycle,
            format: backend.captureFormat,
            continuation: continuation,
            levelHandler: nil,
            usesBluetoothInput: backend.usesBluetoothInput,
            ring: AudioChunkRing(
                maxFrames: Int(backend.maximumFramesPerSlice),
                channelCount: backend.captureChannelCount
            )
        )

        XCTAssertThrowsError(try backend.installCallbacks(for: session))
        backend.cleanup()

        XCTAssertEqual(operations.addedListeners.count, 2)
        XCTAssertEqual(operations.removedListeners.count, 2)
        let firstDispose = try XCTUnwrap(operations.events.firstIndex(of: "dispose"))
        let lastRemoval = try XCTUnwrap(operations.events.lastIndex(of: "removeListener"))
        XCTAssertLessThan(lastRemoval, firstDispose)
        XCTAssertEqual(backend.lifecycle.cleanupStatus, .successful)
    }

    func testVPIOInitializationFailureUsesSessionCleanupExactlyOnceAndRemovesListenersBeforeDispose() throws {
        let operations = RecordingNativeOperations()
        let factory = NativeAudioCaptureBackendFactory(
            operations: operations,
            devices: TestAudioDeviceProvider(outputDevice: 202)
        )
        let backend = try factory.makeBackend(
            configuration: AudioCaptureConfiguration(duckOtherAudio: true),
            inputDevice: 101
        )
        operations.initializeStatus = -10879

        let (_, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        let session = AudioCaptureSession(
            lifecycle: backend.lifecycle,
            format: backend.captureFormat,
            continuation: continuation,
            levelHandler: nil,
            usesBluetoothInput: backend.usesBluetoothInput,
            ring: AudioChunkRing(
                maxFrames: Int(backend.maximumFramesPerSlice),
                channelCount: backend.captureChannelCount
            )
        )
        try backend.installCallbacks(for: session)

        XCTAssertThrowsError(try backend.start())
        session.cleanup()
        session.cleanup()

        XCTAssertEqual(operations.stopCount, 1)
        XCTAssertEqual(operations.uninitializeCount, 1)
        XCTAssertEqual(operations.disposeCount, 1)
        XCTAssertEqual(operations.addedListeners.count, operations.removedListeners.count)
        let firstDispose = try XCTUnwrap(operations.events.firstIndex(of: "dispose"))
        let lastRemoval = try XCTUnwrap(operations.events.lastIndex(of: "removeListener"))
        XCTAssertLessThan(lastRemoval, firstDispose)
    }

    func testVPIOStartFailureUsesSessionCleanupExactlyOnce() throws {
        let operations = RecordingNativeOperations()
        let factory = NativeAudioCaptureBackendFactory(
            operations: operations,
            devices: TestAudioDeviceProvider(outputDevice: 202)
        )
        let backend = try factory.makeBackend(
            configuration: AudioCaptureConfiguration(duckOtherAudio: true),
            inputDevice: 101
        )
        operations.startStatus = -10879

        let (_, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        let session = AudioCaptureSession(
            lifecycle: backend.lifecycle,
            format: backend.captureFormat,
            continuation: continuation,
            levelHandler: nil,
            usesBluetoothInput: backend.usesBluetoothInput,
            ring: AudioChunkRing(
                maxFrames: Int(backend.maximumFramesPerSlice),
                channelCount: backend.captureChannelCount
            )
        )
        try backend.installCallbacks(for: session)

        XCTAssertThrowsError(try backend.start())
        session.cleanup()

        XCTAssertEqual(operations.stopCount, 1)
        XCTAssertEqual(operations.uninitializeCount, 1)
        XCTAssertEqual(operations.disposeCount, 1)
    }

    func testVPIORejectsBypassReadbackWithoutFallingBackToHAL() {
        let operations = RecordingNativeOperations()
        operations.bypassReadbackOverride = 1
        let factory = NativeAudioCaptureBackendFactory(
            operations: operations,
            devices: TestAudioDeviceProvider(outputDevice: 202)
        )

        XCTAssertThrowsError(
            try factory.makeBackend(
                configuration: AudioCaptureConfiguration(duckOtherAudio: true),
                inputDevice: 101
            )
        ) { error in
            guard case let AudioCaptureError.nativeDuckingUnavailable(reason) = error else {
                return XCTFail("Expected native ducking failure, got \(error)")
            }
            XCTAssertTrue(reason.contains("bypass"))
        }
        XCTAssertEqual(operations.createdSubtypes, [UInt32(kAudioUnitSubType_VoiceProcessingIO)])
    }

    func testVPIORejectsEffectiveClientFormatCoercion() throws {
        let operations = RecordingNativeOperations()
        let factory = NativeAudioCaptureBackendFactory(
            operations: operations,
            devices: TestAudioDeviceProvider(outputDevice: 202)
        )
        let backend = try factory.makeBackend(
            configuration: AudioCaptureConfiguration(duckOtherAudio: true),
            inputDevice: 101
        )
        operations.coerceClientFormatsOnReadback = true

        XCTAssertThrowsError(try backend.start()) { error in
            guard case let AudioCaptureError.nativeDuckingUnavailable(reason) = error else {
                return XCTFail("Expected native ducking failure, got \(error)")
            }
            XCTAssertTrue(reason.contains("coerced"))
        }
        backend.cleanup()
        XCTAssertEqual(backend.lifecycle.cleanupStatus, .successful)
    }

    func testVPIORejectsEffectiveMaximumFrameCapacityGrowth() throws {
        let operations = RecordingNativeOperations()
        let factory = NativeAudioCaptureBackendFactory(
            operations: operations,
            devices: TestAudioDeviceProvider(outputDevice: 202)
        )
        let backend = try factory.makeBackend(
            configuration: AudioCaptureConfiguration(duckOtherAudio: true),
            inputDevice: 101
        )
        operations.maximumFramesPerSlice = 1024

        XCTAssertThrowsError(try backend.start()) { error in
            guard case let AudioCaptureError.nativeDuckingUnavailable(reason) = error else {
                return XCTFail("Expected native ducking failure, got \(error)")
            }
            XCTAssertTrue(reason.contains("maximum frame capacity"))
        }
        backend.cleanup()
        XCTAssertEqual(backend.lifecycle.cleanupStatus, .successful)
    }

    func testVPIOStartOutputReadbackMismatchCleansUpWithoutHALFallback() throws {
        let operations = RecordingNativeOperations()
        let factory = NativeAudioCaptureBackendFactory(
            operations: operations,
            devices: TestAudioDeviceProvider(outputDevice: 202)
        )
        let backend = try factory.makeBackend(
            configuration: AudioCaptureConfiguration(duckOtherAudio: true),
            inputDevice: 101
        )
        operations.readbackOverrides[0] = 999

        XCTAssertThrowsError(try backend.start()) { error in
            guard case let AudioCaptureError.nativeDuckingUnavailable(reason) = error else {
                return XCTFail("Expected native ducking failure, got \(error)")
            }
            XCTAssertTrue(reason.contains("output route"))
        }
        backend.cleanup()

        XCTAssertEqual(operations.createdSubtypes, [UInt32(kAudioUnitSubType_VoiceProcessingIO)])
        XCTAssertEqual(operations.stopCount, 1)
        XCTAssertEqual(operations.uninitializeCount, 1)
        XCTAssertEqual(operations.disposeCount, 1)
    }

    func testFailedRouteListenerRemovalRetainsStableBlocksForBoundedRetry() throws {
        let operations = RecordingNativeOperations()
        let factory = NativeAudioCaptureBackendFactory(
            operations: operations,
            devices: TestAudioDeviceProvider(outputDevice: 202)
        )
        let backend = try factory.makeBackend(
            configuration: AudioCaptureConfiguration(duckOtherAudio: true),
            inputDevice: 101
        )
        let (_, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        let session = AudioCaptureSession(
            lifecycle: backend.lifecycle,
            format: backend.captureFormat,
            continuation: continuation,
            levelHandler: nil,
            usesBluetoothInput: backend.usesBluetoothInput,
            ring: AudioChunkRing(
                maxFrames: Int(backend.maximumFramesPerSlice),
                channelCount: backend.captureChannelCount
            )
        )
        try backend.installCallbacks(for: session)
        let added = operations.addedListeners
        XCTAssertFalse(added.isEmpty)

        operations.removeListenerStatus = -10879
        backend.cleanup()
        XCTAssertEqual(backend.lifecycle.cleanupStatus.failedListenerRemovals, added.count)
        XCTAssertFalse(backend.lifecycle.cleanupStatus.isComplete)

        operations.removeListenerStatus = noErr
        NativeAudioUnitFailureQuarantine.retryAllForTesting()

        XCTAssertEqual(backend.lifecycle.cleanupStatus, .successful)
        let retried = Array(operations.removedListeners.dropFirst(added.count))
        XCTAssertEqual(retried.map(\.listenerIdentity), added.map(\.listenerIdentity))
        XCTAssertTrue(retried.allSatisfy { $0.queue === added[0].queue })
    }

    func testFailedDisposeStatusIsObservableAndRetriedFromQuarantine() throws {
        let operations = RecordingNativeOperations()
        operations.disposeStatus = -10879
        let backend = try NativeAudioCaptureBackendFactory(
            operations: operations,
            devices: TestAudioDeviceProvider(outputDevice: 202)
        ).makeBackend(
            configuration: AudioCaptureConfiguration(duckOtherAudio: false),
            inputDevice: 101
        )

        backend.cleanup()
        XCTAssertEqual(backend.lifecycle.cleanupStatus.dispose, -10879)
        XCTAssertFalse(backend.lifecycle.cleanupStatus.isComplete)
        XCTAssertEqual(operations.disposeCount, 1)

        operations.disposeStatus = noErr
        NativeAudioUnitFailureQuarantine.retryAllForTesting()

        XCTAssertEqual(backend.lifecycle.cleanupStatus, .successful)
        XCTAssertEqual(operations.disposeCount, 2)
    }

    func testVPIORouteChangeRunsExistingSessionCleanupAndStopsListening() async throws {
        let operations = RecordingNativeOperations()
        let factory = NativeAudioCaptureBackendFactory(
            operations: operations,
            devices: TestAudioDeviceProvider(outputDevice: 202)
        )
        let backend = try factory.makeBackend(
            configuration: AudioCaptureConfiguration(duckOtherAudio: true),
            inputDevice: 101
        )

        let (_, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        let session = AudioCaptureSession(
            lifecycle: backend.lifecycle,
            format: backend.captureFormat,
            continuation: continuation,
            levelHandler: nil,
            usesBluetoothInput: backend.usesBluetoothInput,
            ring: AudioChunkRing(
                maxFrames: Int(backend.maximumFramesPerSlice),
                channelCount: backend.captureChannelCount
            )
        )
        try backend.installCallbacks(for: session)
        operations.fireFirstPropertyListener()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(operations.stopCount, 1)
        XCTAssertEqual(operations.uninitializeCount, 1)
        XCTAssertEqual(operations.disposeCount, 1)
        XCTAssertEqual(operations.addedListeners.count, operations.removedListeners.count)
    }

    func testRouteEventBeforeStartPreventsStartingDisposedSession() async throws {
        let operations = RecordingNativeOperations()
        let factory = NativeAudioCaptureBackendFactory(
            operations: operations,
            devices: TestAudioDeviceProvider(outputDevice: 202)
        )
        let backend = try factory.makeBackend(
            configuration: AudioCaptureConfiguration(duckOtherAudio: true),
            inputDevice: 101
        )
        let (_, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        let session = AudioCaptureSession(
            lifecycle: backend.lifecycle,
            format: backend.captureFormat,
            continuation: continuation,
            levelHandler: nil,
            usesBluetoothInput: backend.usesBluetoothInput,
            ring: AudioChunkRing(
                maxFrames: Int(backend.maximumFramesPerSlice),
                channelCount: backend.captureChannelCount
            )
        )
        try backend.installCallbacks(for: session)
        operations.fireFirstPropertyListener()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(session.cleanupRequested)

        XCTAssertThrowsError(try backend.start())
        XCTAssertEqual(operations.startStatus, noErr)
        XCTAssertEqual(operations.stopCount, 1)
        XCTAssertEqual(operations.uninitializeCount, 1)
        XCTAssertEqual(operations.disposeCount, 1)
    }

    func testConcurrentQueuedRouteCallbacksDrainBeforeCleanup() async throws {
        let operations = RecordingNativeOperations()
        let factory = NativeAudioCaptureBackendFactory(
            operations: operations,
            devices: TestAudioDeviceProvider(outputDevice: 202)
        )
        let backend = try factory.makeBackend(
            configuration: AudioCaptureConfiguration(duckOtherAudio: true),
            inputDevice: 101
        )

        let (_, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        let session = AudioCaptureSession(
            lifecycle: backend.lifecycle,
            format: backend.captureFormat,
            continuation: continuation,
            levelHandler: nil,
            usesBluetoothInput: backend.usesBluetoothInput,
            ring: AudioChunkRing(
                maxFrames: Int(backend.maximumFramesPerSlice),
                channelCount: backend.captureChannelCount
            )
        )
        try backend.installCallbacks(for: session)
        operations.firePropertyListenersConcurrently()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(operations.stopCount, 1)
        XCTAssertEqual(operations.uninitializeCount, 1)
        XCTAssertEqual(operations.disposeCount, 1)
        XCTAssertEqual(operations.addedListeners.count, operations.removedListeners.count)
    }

    func testSilenceRenderCallbackClearsEveryProvidedBufferAndSetsSilenceFlag() throws {
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        let first = UnsafeMutableRawPointer.allocate(byteCount: 16, alignment: MemoryLayout<Float>.alignment)
        let second = UnsafeMutableRawPointer.allocate(byteCount: 24, alignment: MemoryLayout<Float>.alignment)
        defer {
            first.deallocate()
            second.deallocate()
            list.unsafeMutablePointer.deallocate()
        }
        first.initializeMemory(as: UInt8.self, repeating: 0xA5, count: 16)
        second.initializeMemory(as: UInt8.self, repeating: 0xA5, count: 24)
        list.count = 2
        list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 16, mData: first)
        list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 24, mData: second)

        var flags = AudioUnitRenderActionFlags(rawValue: 0)
        var timestamp = AudioTimeStamp()
        let status = silenceRenderCallback(
            refCon: UnsafeMutableRawPointer(bitPattern: 1)!,
            actionFlags: &flags,
            timeStamp: &timestamp,
            busNumber: 0,
            frames: 6,
            data: list.unsafeMutablePointer
        )

        XCTAssertEqual(status, noErr)
        XCTAssertEqual(flags.rawValue & (1 << 4), 1 << 4)
        XCTAssertTrue(UnsafeBufferPointer(
            start: first.assumingMemoryBound(to: UInt8.self),
            count: 16
        ).allSatisfy { $0 == 0 })
        XCTAssertTrue(UnsafeBufferPointer(
            start: second.assumingMemoryBound(to: UInt8.self),
            count: 24
        ).allSatisfy { $0 == 0 })
    }
}

private func makeFormat(sampleRate: Float64, channels: UInt32) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: channels * UInt32(MemoryLayout<Float32>.size),
        mFramesPerPacket: 1,
        mBytesPerFrame: channels * UInt32(MemoryLayout<Float32>.size),
        mChannelsPerFrame: channels,
        mBitsPerChannel: UInt32(MemoryLayout<Float32>.size * 8),
        mReserved: 0
    )
}

private final class TestAudioDeviceProvider: AudioDeviceProvider, @unchecked Sendable {
    let outputDevice: AudioDeviceID
    private(set) var defaultOutputReadCount = 0
    private(set) var defaultWriteCount = 0

    init(outputDevice: AudioDeviceID) {
        self.outputDevice = outputDevice
    }

    func defaultOutputDeviceID() -> AudioDeviceID? {
        defaultOutputReadCount += 1
        return outputDevice
    }

    func isBluetoothInputDevice(_ device: AudioDeviceID) -> Bool {
        false
    }
}

private final class RecordingNativeOperations: AudioUnitNativeOperations, @unchecked Sendable {
    struct PropertyCall {
        let property: AudioUnitPropertyID
        let scope: AudioUnitScope
        let element: AudioUnitElement
        let size: UInt32
        let bytes: [UInt8]
    }

    struct FormatWrite {
        let scope: AudioUnitScope
        let element: AudioUnitElement
        let format: AudioStreamBasicDescription
    }

    struct ListenerCall: @unchecked Sendable {
        let objectID: AudioObjectID
        let address: AudioObjectPropertyAddress
        let queue: DispatchQueue
        let listener: AudioObjectPropertyListenerBlock

        var listenerIdentity: ObjectIdentifier {
            ObjectIdentifier(listener as AnyObject)
        }
    }

    let handle = NativeAudioUnitHandle(raw: nil)
    let inputHardware: AudioStreamBasicDescription
    let outputHardware: AudioStreamBasicDescription
    private(set) var createdSubtypes: [UInt32] = []
    private(set) var setCalls: [PropertyCall] = []
    private(set) var formatWrites: [FormatWrite] = []
    private(set) var currentDeviceWrites: [AudioUnitElement: AudioDeviceID] = [:]
    var readbackOverrides: [AudioUnitElement: AudioDeviceID] = [:]
    var initializeStatus: OSStatus = noErr
    var startStatus: OSStatus = noErr
    var stopStatus: OSStatus = noErr
    var uninitializeStatus: OSStatus = noErr
    var setStatus: OSStatus = noErr
    var getStatus: OSStatus = noErr
    var addListenerStatus: OSStatus = noErr
    var failRouteListenerAddAfter: Int?
    private var addListenerCount = 0
    var removeListenerStatus: OSStatus = noErr
    var disposeStatus: OSStatus = noErr
    var maximumFramesPerSlice: UInt32 = 512
    var bypassReadbackOverride: UInt32?
    var coerceClientFormatsOnReadback = false
    private(set) var stopCount = 0
    private(set) var uninitializeCount = 0
    private(set) var disposeCount = 0
    private(set) var events: [String] = []
    private(set) var addedListeners: [ListenerCall] = []
    private(set) var removedListeners: [ListenerCall] = []
    private var agcValue: UInt32 = 0
    private var bypassValue: UInt32 = 0
    private var formatValues: [FormatKey: AudioStreamBasicDescription] = [:]

    private struct FormatKey: Hashable {
        let scope: AudioUnitScope
        let element: AudioUnitElement
    }

    init(
        inputHardware: AudioStreamBasicDescription = makeFormat(sampleRate: 48_000, channels: 2),
        outputHardware: AudioStreamBasicDescription = makeFormat(sampleRate: 48_000, channels: 2)
    ) {
        self.inputHardware = inputHardware
        self.outputHardware = outputHardware
    }

    func makeUnit(componentSubType: UInt32) throws -> NativeAudioUnitHandle {
        createdSubtypes.append(componentSubType)
        return handle
    }

    func setProperty(
        _ unit: NativeAudioUnitHandle,
        property: AudioUnitPropertyID,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        data: UnsafeMutableRawPointer,
        size: UInt32
    ) -> OSStatus {
        let bytes = Array(UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: UInt8.self),
            count: Int(size)
        ))
        setCalls.append(PropertyCall(property: property, scope: scope, element: element, size: size, bytes: bytes))
        if property == kAudioOutputUnitProperty_CurrentDevice {
            currentDeviceWrites[element] = data.load(as: AudioDeviceID.self)
        }
        if property == kAUVoiceIOProperty_VoiceProcessingEnableAGC {
            agcValue = data.load(as: UInt32.self)
        }
        if property == kAUVoiceIOProperty_BypassVoiceProcessing {
            bypassValue = data.load(as: UInt32.self)
        }
        if property == kAudioUnitProperty_StreamFormat {
            let format = data.load(as: AudioStreamBasicDescription.self)
            formatValues[FormatKey(scope: scope, element: element)] = format
            formatWrites.append(FormatWrite(
                scope: scope,
                element: element,
                format: format
            ))
        }
        return setStatus
    }

    func getProperty(
        _ unit: NativeAudioUnitHandle,
        property: AudioUnitPropertyID,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        data: UnsafeMutableRawPointer,
        size: inout UInt32
    ) -> OSStatus {
        guard getStatus == noErr else { return getStatus }
        switch property {
        case kAudioOutputUnitProperty_CurrentDevice:
            data.storeBytes(
                of: readbackOverrides[element] ?? currentDeviceWrites[element] ?? AudioDeviceID(kAudioObjectUnknown),
                as: AudioDeviceID.self
            )
            size = UInt32(MemoryLayout<AudioDeviceID>.size)
        case kAudioUnitProperty_StreamFormat:
            var format = formatValues[FormatKey(scope: scope, element: element)]
                ?? (scope == kAudioUnitScope_Input && element == 1 ? inputHardware : outputHardware)
            if coerceClientFormatsOnReadback,
               formatValues[FormatKey(scope: scope, element: element)] != nil {
                format.mChannelsPerFrame += 1
            }
            data.storeBytes(of: format, as: AudioStreamBasicDescription.self)
            size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        case kAudioUnitProperty_MaximumFramesPerSlice:
            data.storeBytes(of: maximumFramesPerSlice, as: UInt32.self)
            size = UInt32(MemoryLayout<UInt32>.size)
        case kAUVoiceIOProperty_VoiceProcessingEnableAGC:
            data.storeBytes(of: agcValue, as: UInt32.self)
            size = UInt32(MemoryLayout<UInt32>.size)
        case kAUVoiceIOProperty_BypassVoiceProcessing:
            data.storeBytes(of: bypassReadbackOverride ?? bypassValue, as: UInt32.self)
            size = UInt32(MemoryLayout<UInt32>.size)
        default:
            break
        }
        return noErr
    }

    func initialize(_ unit: NativeAudioUnitHandle) -> OSStatus {
        events.append("initialize")
        return initializeStatus
    }

    func start(_ unit: NativeAudioUnitHandle) -> OSStatus {
        events.append("start")
        return startStatus
    }

    func stop(_ unit: NativeAudioUnitHandle) -> OSStatus {
        stopCount += 1
        events.append("stop")
        return stopStatus
    }

    func uninitialize(_ unit: NativeAudioUnitHandle) -> OSStatus {
        uninitializeCount += 1
        events.append("uninitialize")
        return uninitializeStatus
    }

    func dispose(_ unit: NativeAudioUnitHandle) -> OSStatus {
        disposeCount += 1
        events.append("dispose")
        return disposeStatus
    }

    func render(
        _ unit: NativeAudioUnitHandle,
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        busNumber: UInt32,
        frames: UInt32,
        data: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        noErr
    }

    func addPropertyListenerBlock(
        objectID: AudioObjectID,
        address: UnsafeMutablePointer<AudioObjectPropertyAddress>,
        queue: DispatchQueue,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        if let failRouteListenerAddAfter, addListenerCount >= failRouteListenerAddAfter {
            addListenerCount += 1
            return -10879
        }
        addListenerCount += 1
        guard addListenerStatus == noErr else { return addListenerStatus }
        addedListeners.append(ListenerCall(
            objectID: objectID,
            address: address.pointee,
            queue: queue,
            listener: listener
        ))
        return noErr
    }

    func removePropertyListenerBlock(
        objectID: AudioObjectID,
        address: UnsafeMutablePointer<AudioObjectPropertyAddress>,
        queue: DispatchQueue,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        events.append("removeListener")
        removedListeners.append(ListenerCall(
            objectID: objectID,
            address: address.pointee,
            queue: queue,
            listener: listener
        ))
        return removeListenerStatus
    }

    func fireFirstPropertyListener() {
        guard let call = addedListeners.first else { return }
        var address = call.address
        withUnsafePointer(to: &address) { pointer in
            call.listener(1, pointer)
        }
    }

    func firePropertyListenersConcurrently() {
        let calls = addedListeners
        guard !calls.isEmpty else { return }
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            let call = calls[index % calls.count]
            var address = call.address
            withUnsafePointer(to: &address) { pointer in
                call.listener(1, pointer)
            }
        }
    }
}
