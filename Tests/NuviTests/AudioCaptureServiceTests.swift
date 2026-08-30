import XCTest
import AVFoundation
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
