import XCTest
import AVFoundation
import AudioToolbox
@testable import Nuvi

final class AudioCaptureServiceTests: XCTestCase {
    func testSessionCleanupStopsResourcesBeforeFinishingStream() async {
        let recorder = EventRecorder()
        let lifecycle = RecordingAudioUnitLifecycle(recorder: recorder)
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        continuation.onTermination = { _ in recorder.append("finish") }

        let drain = Task {
            for await _ in stream {}
        }

        let session = AudioCaptureSession(
            lifecycle: lifecycle,
            format: nil,
            continuation: continuation,
            levelHandler: nil,
            usesBluetoothInput: false
        )

        session.cleanup()
        await drain.value

        XCTAssertEqual(recorder.events, ["stop", "uninitialize", "dispose", "finish"])
    }

    func testSessionCleanupIsIdempotentAndRetainsOwnershipUntilCleanup() {
        let recorder = EventRecorder()
        let lifecycle = RecordingAudioUnitLifecycle(recorder: recorder)
        let (_, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        let session = AudioCaptureSession(
            lifecycle: lifecycle,
            format: nil,
            continuation: continuation,
            levelHandler: nil,
            usesBluetoothInput: false
        )

        session.cleanup()
        session.cleanup()

        XCTAssertEqual(recorder.events, ["stop", "uninitialize", "dispose"])
    }

    func testCancellationBeforePublisherStartDoesNotReenterCleanup() async {
        let recorder = EventRecorder()
        let lifecycle = RecordingAudioUnitLifecycle(recorder: recorder)
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        let session = AudioCaptureSession(
            lifecycle: lifecycle,
            format: nil,
            continuation: continuation,
            levelHandler: nil,
            usesBluetoothInput: false
        )
        session.installTerminationHandler()

        let consumer = Task {
            for await _ in stream {}
        }
        consumer.cancel()
        await consumer.value

        XCTAssertEqual(recorder.events, ["stop", "uninitialize", "dispose"])
    }

    func testServiceDeinitCleansUpOwnedSession() async {
        let recorder = EventRecorder()
        let lifecycle = RecordingAudioUnitLifecycle(recorder: recorder)
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        continuation.onTermination = { _ in recorder.append("finish") }
        let session = AudioCaptureSession(
            lifecycle: lifecycle,
            format: nil,
            continuation: continuation,
            levelHandler: nil,
            usesBluetoothInput: false
        )
        let drain = Task {
            for await _ in stream {}
        }

        do {
            let service = AudioCaptureService(activeSession: session)
            withExtendedLifetime(service) {}
        }

        await drain.value
        XCTAssertEqual(recorder.events, ["stop", "uninitialize", "dispose", "finish"])
    }

    func testOversizedRenderSignalsFatalCleanupToPublisher() async {
        let recorder = EventRecorder()
        let lifecycle = RecordingAudioUnitLifecycle(recorder: recorder)
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        let session = AudioCaptureSession(
            lifecycle: lifecycle,
            format: nil,
            continuation: continuation,
            levelHandler: nil,
            usesBluetoothInput: false,
            ring: AudioChunkRing(maxFrames: 1, channelCount: 1)
        )
        let consumer = Task {
            for await _ in stream {}
        }
        session.startPublisher()

        let list = AudioBufferList.allocate(maximumBuffers: 1)
        defer { list.unsafeMutablePointer.deallocate() }
        var flags = AudioUnitRenderActionFlags(rawValue: 0)
        var timestamp = AudioTimeStamp()
        let status = session.render(
            actionFlags: &flags,
            timeStamp: &timestamp,
            busNumber: 0,
            frames: 2
        )

        XCTAssertEqual(status, AudioCaptureSession.fatalRenderStatus)
        XCTAssertTrue(session.fatalRenderCleanupRequested)
        await consumer.value
        XCTAssertEqual(recorder.events, ["stop", "uninitialize", "dispose"])
    }

    func testConcurrentStartAndStopSerializeSessionOwnership() async throws {
        let recorder = EventRecorder()
        let lifecycle = RecordingAudioUnitLifecycle(recorder: recorder)
        let backend = TestAudioCaptureBackend(lifecycle: lifecycle)
        let factory = BlockingAudioCaptureBackendFactory(backend: backend)
        let service = AudioCaptureService(
            backendFactory: factory,
            inputDeviceOverride: 101
        )

        let startTask = Task.detached { () -> Bool in
            do {
                _ = try service.start(configuration: AudioCaptureConfiguration(duckOtherAudio: false))
                return true
            } catch {
                return false
            }
        }
        XCTAssertEqual(factory.makeEntered.wait(timeout: .now() + 1), .success)

        let stopFinished = DispatchSemaphore(value: 0)
        let stopTask = Task.detached {
            service.stop()
            stopFinished.signal()
        }
        XCTAssertEqual(stopFinished.wait(timeout: .now() + 0.05), .timedOut)

        factory.releaseMake.signal()
        let started = await startTask.value
        XCTAssertTrue(started)
        await stopTask.value

        XCTAssertEqual(factory.makeCount, 1)
        XCTAssertEqual(recorder.events, ["stop", "uninitialize", "dispose"])
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
}

private final class RecordingAudioUnitLifecycle: AudioUnitLifecycle, @unchecked Sendable {
    let unit: AudioUnit? = nil
    private let recorder: EventRecorder

    init(recorder: EventRecorder) {
        self.recorder = recorder
    }

    func stop() {
        recorder.append("stop")
    }

    func uninitialize() {
        recorder.append("uninitialize")
    }

    func dispose() {
        recorder.append("dispose")
    }
}

private final class TestAudioCaptureBackend: AudioCaptureBackend, @unchecked Sendable {
    let kind: AudioCaptureBackendKind = .hal
    let lifecycle: AudioUnitLifecycle
    let captureFormat: AVAudioFormat
    let captureChannelCount = 1
    let maximumFramesPerSlice: UInt32 = 1
    let usesBluetoothInput = false
    let diagnostics: AudioCaptureDiagnostics

    init(lifecycle: AudioUnitLifecycle) {
        self.lifecycle = lifecycle
        captureFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        diagnostics = AudioCaptureDiagnostics(
            requestedBackend: .hal,
            effectiveBackend: nil,
            selectedInputUID: nil,
            selectedInputID: 101,
            boundInputID: 101,
            boundOutputID: nil,
            inputClientFormat: nil,
            outputClientFormat: nil,
            maximumFramesPerSlice: 1,
            cleanupComplete: false
        )
    }

    func installCallbacks(for session: AudioCaptureSession) throws {}
    func start() throws {}
    func cleanup() {}
}

private final class BlockingAudioCaptureBackendFactory: AudioCaptureBackendFactory, @unchecked Sendable {
    let backend: AudioCaptureBackend
    let makeEntered = DispatchSemaphore(value: 0)
    let releaseMake = DispatchSemaphore(value: 0)
    private(set) var makeCount = 0

    init(backend: AudioCaptureBackend) {
        self.backend = backend
    }

    func makeBackend(
        configuration: AudioCaptureConfiguration,
        inputDevice: AudioDeviceID
    ) throws -> AudioCaptureBackend {
        _ = configuration
        _ = inputDevice
        makeCount += 1
        makeEntered.signal()
        releaseMake.wait()
        return backend
    }
}
