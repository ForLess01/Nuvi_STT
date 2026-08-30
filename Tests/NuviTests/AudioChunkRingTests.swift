import XCTest
import AVFoundation
import AudioToolbox
@testable import Nuvi

final class AudioChunkRingTests: XCTestCase {
    func testRingPreservesPlanarFIFOOrder() {
        let ring = AudioChunkRing(maxFrames: 4, channelCount: 2, capacity: 2)

        XCTAssertTrue(isReserved(ring.enqueue(planarSamples: [[1, 2], [10, 20]])))
        XCTAssertTrue(isReserved(ring.enqueue(planarSamples: [[3, 4], [30, 40]])))

        let first = try! XCTUnwrap(ring.pop())
        XCTAssertEqual(first.frameCount, 2)
        XCTAssertEqual(read(first, channel: 0), [1, 2])
        XCTAssertEqual(read(first, channel: 1), [10, 20])
        ring.release(first)

        let second = try! XCTUnwrap(ring.pop())
        XCTAssertEqual(read(second, channel: 0), [3, 4])
        XCTAssertEqual(read(second, channel: 1), [30, 40])
        ring.release(second)
        XCTAssertNil(ring.pop())
    }

    func testFullRingDropsNewestSliceWithoutOverwritingOldest() {
        let ring = AudioChunkRing(maxFrames: 2, channelCount: 1, capacity: 2)

        XCTAssertTrue(isReserved(ring.enqueue(planarSamples: [[1]])))
        XCTAssertTrue(isReserved(ring.enqueue(planarSamples: [[2]])))
        XCTAssertEqual(resultName(ring.enqueue(planarSamples: [[3]])), "full")
        XCTAssertEqual(ring.droppedNewestCount, 1)

        let first = try! XCTUnwrap(ring.pop())
        XCTAssertEqual(read(first, channel: 0), [1])
        ring.release(first)
        let second = try! XCTUnwrap(ring.pop())
        XCTAssertEqual(read(second, channel: 0), [2])
        ring.release(second)
        XCTAssertNil(ring.pop())
    }

    func testFullRingUsesStablePreallocatedDiscardSink() throws {
        let ring = AudioChunkRing(maxFrames: 2, channelCount: 1, capacity: 1)

        XCTAssertTrue(isReserved(ring.enqueue(planarSamples: [[1]])))
        XCTAssertEqual(resultName(ring.enqueue(planarSamples: [[2]])), "full")

        let first = try XCTUnwrap(ring.discardBufferList(frames: 2, channelCount: 1))
        let firstData = first.pointee.mBuffers.mData
        first.pointee.mBuffers.mDataByteSize = 0

        let second = try XCTUnwrap(ring.discardBufferList(frames: 2, channelCount: 1))
        XCTAssertEqual(second, first, "the discard destination must be preallocated and stable")
        XCTAssertEqual(second.pointee.mBuffers.mData, firstData)
        XCTAssertEqual(
            second.pointee.mBuffers.mDataByteSize,
            UInt32(2 * MemoryLayout<Float>.stride),
            "discard preparation must restore the full destination capacity"
        )
        XCTAssertNil(ring.discardBufferList(frames: 3, channelCount: 1))
    }

    func testOversizedSlicesAreCountedAndNeverResizeTheRing() {
        let ring = AudioChunkRing(maxFrames: 2, channelCount: 1, capacity: 2)

        XCTAssertEqual(resultName(ring.enqueue(planarSamples: [[1, 2, 3]])), "oversized")
        XCTAssertEqual(resultName(ring.enqueue(planarSamples: [[1], [2]])), "oversized")
        XCTAssertEqual(ring.oversizedSliceCount, 2)
        XCTAssertNil(ring.pop())
    }

    func testCloseRejectsNewSlicesAndDrainsPublishedSlots() {
        let ring = AudioChunkRing(maxFrames: 2, channelCount: 1, capacity: 2)
        XCTAssertTrue(isReserved(ring.enqueue(planarSamples: [[7, 8]])))

        ring.close()
        XCTAssertTrue(ring.isClosed)
        XCTAssertEqual(resultName(ring.enqueue(planarSamples: [[9]])), "closed")

        ring.drain()
        XCTAssertNil(ring.pop())
    }

    func testPublisherCopiesUniqueBuffersAndEmitsLevelOffCallback() async throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let ring = AudioChunkRing(maxFrames: 4, channelCount: 1, capacity: 2)
        let lifecycle = TestAudioUnitLifecycle()
        let levels = LockedValues<Float>()
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(
            bufferingPolicy: .bufferingOldest(2)
        )
        let session = AudioCaptureSession(
            lifecycle: lifecycle,
            format: format,
            continuation: continuation,
            levelHandler: { levels.append($0) },
            usesBluetoothInput: false,
            ring: ring,
            levelEmissionIntervalNanos: 0
        )
        var iterator = stream.makeAsyncIterator()

        XCTAssertTrue(isReserved(ring.enqueue(planarSamples: [[0.25, -0.25]])))
        session.publishAvailableChunksForTesting()
        let firstValue = await iterator.next()
        let first = try XCTUnwrap(firstValue)
        XCTAssertEqual(read(first, channel: 0), [0.25, -0.25])

        XCTAssertTrue(isReserved(ring.enqueue(planarSamples: [[0.5, -0.5]])))
        session.publishAvailableChunksForTesting()
        let secondValue = await iterator.next()
        let second = try XCTUnwrap(secondValue)
        XCTAssertEqual(read(second, channel: 0), [0.5, -0.5])
        XCTAssertNotEqual(
            first.floatChannelData![0],
            second.floatChannelData![0],
            "Every yielded buffer must own its retained samples"
        )
        XCTAssertEqual(levels.values.count, 2)
        XCTAssertTrue(levels.values.allSatisfy { $0 > 0 })

        session.cleanup()
        let end = await iterator.next()
        XCTAssertNil(end)
        XCTAssertEqual(levels.values.last, 0)
        XCTAssertEqual(lifecycle.events, ["stop", "uninitialize", "dispose"])
    }

    func testPublisherAccountsForBoundedStreamDropsWithoutReorderingOldest() async throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let ring = AudioChunkRing(maxFrames: 1, channelCount: 1, capacity: 4)
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(
            bufferingPolicy: .bufferingOldest(1)
        )
        let session = AudioCaptureSession(
            lifecycle: TestAudioUnitLifecycle(),
            format: format,
            continuation: continuation,
            levelHandler: nil,
            usesBluetoothInput: false,
            ring: ring,
            levelEmissionIntervalNanos: 0
        )

        var iterator = stream.makeAsyncIterator()
        for value in 1...3 {
            XCTAssertTrue(isReserved(ring.enqueue(planarSamples: [[Float(value)]])))
            session.publishAvailableChunksForTesting()
        }

        XCTAssertEqual(session.droppedStreamCount, 2)
        let firstValue = await iterator.next()
        let first = try XCTUnwrap(firstValue)
        XCTAssertEqual(read(first, channel: 0), [1], "bufferingOldest keeps the earliest queued audio")
        session.cleanup()
    }

    func testBluetoothGainAndLevelComputationStayOnPublisherPath() async throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let ring = AudioChunkRing(maxFrames: 2, channelCount: 1, capacity: 2)
        let levels = LockedValues<Float>()
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(
            bufferingPolicy: .bufferingOldest(2)
        )
        let session = AudioCaptureSession(
            lifecycle: TestAudioUnitLifecycle(),
            format: format,
            continuation: continuation,
            levelHandler: { levels.append($0) },
            usesBluetoothInput: true,
            ring: ring,
            levelEmissionIntervalNanos: 1_000_000_000
        )
        var iterator = stream.makeAsyncIterator()

        XCTAssertTrue(isReserved(ring.enqueue(planarSamples: [[0.01, 0.01]])))
        session.publishAvailableChunksForTesting()
        let value = await iterator.next()
        let buffer = try XCTUnwrap(value)

        // The adaptive Bluetooth speech boost starts moving toward its target
        // on this first quiet slice; the publisher therefore emits a value
        // above the raw input while the callback remains sample-processing-free.
        XCTAssertGreaterThan(read(buffer, channel: 0)[0], 0.01)
        XCTAssertEqual(levels.values.count, 1)
        XCTAssertGreaterThan(levels.values[0], 0)

        XCTAssertTrue(isReserved(ring.enqueue(planarSamples: [[0.01, 0.01]])))
        session.publishAvailableChunksForTesting()
        _ = await iterator.next()
        XCTAssertEqual(levels.values.count, 1, "RMS level delivery is throttled off the callback")

        session.cleanup()
    }

    func testStreamTerminationClosesAdmissionWaitsCallbacksAndFinishes() async {
        let lifecycle = TestAudioUnitLifecycle()
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        let session = AudioCaptureSession(
            lifecycle: lifecycle,
            format: nil,
            continuation: continuation,
            levelHandler: nil,
            usesBluetoothInput: false
        )
        session.installTerminationHandler()
        session.startPublisher()

        XCTAssertTrue(session.enterCallback())
        let cleanupFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            session.cleanup()
            cleanupFinished.signal()
        }

        XCTAssertEqual(
            cleanupFinished.wait(timeout: .now() + 0.05),
            .timedOut,
            "Cleanup must wait for an in-flight callback"
        )
        XCTAssertFalse(session.enterCallback(), "Closing admission rejects a new callback")
        session.leaveCallback()
        XCTAssertEqual(cleanupFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(lifecycle.events, ["stop", "uninitialize", "dispose"])

        // The termination handler is installed on the returned stream and the
        // publisher task has exited; consuming the finished stream is enough
        // to prove the continuation was completed without microphone hardware.
        var iterator = stream.makeAsyncIterator()
        let end = await iterator.next()
        XCTAssertNil(end)
    }

    func testCancelledConsumerTriggersSessionTeardown() async {
        let lifecycle = TestAudioUnitLifecycle()
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        let session = AudioCaptureSession(
            lifecycle: lifecycle,
            format: nil,
            continuation: continuation,
            levelHandler: nil,
            usesBluetoothInput: false
        )
        session.installTerminationHandler()
        session.startPublisher()

        let consumer = Task {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next() == nil
        }
        consumer.cancel()
        let cancellationObserved = await consumer.value
        XCTAssertTrue(cancellationObserved)
        XCTAssertEqual(lifecycle.disposed.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(lifecycle.events, ["stop", "uninitialize", "dispose"])
    }

    private func isReserved(_ result: AudioChunkWriteResult) -> Bool {
        if case .reserved = result { return true }
        return false
    }

    private func resultName(_ result: AudioChunkWriteResult) -> String {
        switch result {
        case .reserved: return "reserved"
        case .full: return "full"
        case .oversized: return "oversized"
        case .closed: return "closed"
        }
    }

    private func read(_ chunk: AudioChunkRing.Chunk, channel: Int) -> [Float] {
        Array(UnsafeBufferPointer(start: chunk.channelData[channel], count: chunk.frameCount))
    }

    private func read(_ buffer: AVAudioPCMBuffer, channel: Int) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[channel], count: Int(buffer.frameLength)))
    }
}

private final class TestAudioUnitLifecycle: AudioUnitLifecycle, @unchecked Sendable {
    let unit: AudioUnit? = nil
    let disposed = DispatchSemaphore(value: 0)
    private(set) var events: [String] = []

    func stop() { events.append("stop") }
    func uninitialize() { events.append("uninitialize") }
    func dispose() {
        events.append("dispose")
        disposed.signal()
    }
}

private final class LockedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
