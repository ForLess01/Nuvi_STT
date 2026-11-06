import AVFoundation
import XCTest
@testable import Nuvi

final class SpeechStreamSessionTests: XCTestCase {
    func testBlockedWhisperDecoderDoesNotBlockEightBufferIntake() async throws {
        let decoder = BlockingSpeechDecoder()
        let (audio, input) = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .bufferingOldest(8))
        let output = SpeechStreamSessions.whisper(audio: audio, minimumSamples: 1, cadence: 1,
                                                windowCapacity: 4, maximumSamples: 32) {
            try await decoder.decode($0)
        }
        let consumer = Task { () throws -> [String] in
            var events: [String] = []
            for try await event in output {
                if case .final(let text) = event { events.append(text) }
            }
            return events
        }
        input.yield(makeBuffer(0))
        await fulfillment(of: [decoder.entered], timeout: 3)
        var drops = 0
        for value in 1...20 {
            if case .dropped = input.yield(makeBuffer(Float(value))) { drops += 1 }
            // Model a live producer, not an instantaneous burst that itself
            // legitimately exceeds the upstream queue's capacity.
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        input.finish()
        await decoder.release()
        let finals = try await consumer.value
        let calls = await decoder.calls
        XCTAssertEqual(drops, 0)
        XCTAssertEqual(calls.last, (0...20).map(Float.init))
        XCTAssertTrue(calls.dropLast().allSatisfy { $0.count <= 4 })
        XCTAssertLessThanOrEqual(calls.count, 3, "Only one running and one coalesced partial")
        XCTAssertEqual(finals, ["decoded"])
    }

    func testParakeetCleanupRunsOnceForFinishFailureLimitCancellationAndSuccess() async {
        for failure: CleanupFailure? in [.finish, .limit, .cancelled, nil] {
            var cleanups = 0
            var consumerJoined = false
            let (updates, continuation) = AsyncStream<Int>.makeStream()
            let consumer = Task { for await _ in updates {} }
            do {
                let value = try await SpeechStreamSessions.withCleanup(operation: {
                    if let failure { throw failure }
                    return 7
                }, cleanup: {
                    cleanups += 1
                    continuation.finish()
                    consumer.cancel()
                    await consumer.value
                    consumerJoined = true
                })
                XCTAssertNil(failure)
                XCTAssertEqual(value, 7)
            } catch {
                XCTAssertEqual(error as? CleanupFailure, failure)
            }
            XCTAssertEqual(cleanups, 1, "cleanup must run for \(String(describing: failure))")
            XCTAssertTrue(consumerJoined)
            // Avoid leaving a task in the failing baseline fixture itself.
            continuation.finish()
            consumer.cancel()
            await consumer.value
        }
    }

    func testWhisperLimitRejectsOversizedSessionBeforeFinalDecode() async {
        let (audio, input) = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .bufferingOldest(8))
        for value in 0...4 { input.yield(makeBuffer(Float(value))) }
        input.finish()
        let output = SpeechStreamSessions.whisper(audio: audio, minimumSamples: 10, cadence: 1,
                                                 windowCapacity: 2, maximumSamples: 4) { _ in
            XCTFail("An oversized session must not reach the final decoder")
            return "unexpected"
        }
        do {
            for try await _ in output { XCTFail("Unexpected transcript") }
            XCTFail("Expected input limit error")
        } catch {
            guard case .underlying(let message) = error as? TranscriptionError else {
                return XCTFail("Expected typed limit error, got \(error)")
            }
            XCTAssertEqual(message, "WhisperKit input exceeded 10 minute limit")
        }
    }

    func testWhisperEmptySessionPreservesNoAudioError() async {
        let (audio, input) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        input.finish()
        do {
            for try await _ in SpeechStreamSessions.whisper(audio: audio, cadence: 1, decode: { _ in
                XCTFail("Empty audio must not reach decoder")
                return ""
            }) {}
            XCTFail("Expected no audio error")
        } catch {
            XCTAssertEqual(error as? NuviError, .noAudioReceived)
        }
    }

    func testCancelledOperationStillJoinsCleanupExactlyOnce() async {
        let started = XCTestExpectation(description: "operation waiting")
        let probe = CleanupProbe()
        let (input, continuation) = AsyncStream<Int>.makeStream()
        let task = Task {
            try await SpeechStreamSessions.withCleanup(operation: {
                started.fulfill()
                for await _ in input {}
                try Task.checkCancellation()
            }, cleanup: {
                await probe.cleaned()
            })
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        let count = await probe.count
        XCTAssertEqual(count, 1)
        continuation.finish()
    }

    private func makeBuffer(_ value: Float) -> sending AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                  channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        buffer.frameLength = 1
        buffer.floatChannelData![0][0] = value
        return buffer
    }
}

private actor BlockingSpeechDecoder {
    nonisolated let entered = XCTestExpectation(description: "decoder started")
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var calls: [[Float]] = []
    func decode(_ samples: [Float]) async throws -> String {
        calls.append(samples)
        if calls.count == 1 {
            await withCheckedContinuation { continuation in
                waiter = continuation
                entered.fulfill()
            }
        }
        return "decoded"
    }
    func release() { waiter?.resume(); waiter = nil }
}

private enum CleanupFailure: Error { case finish, limit, cancelled }

private actor CleanupProbe {
    private(set) var count = 0
    func cleaned() { count += 1 }
}
