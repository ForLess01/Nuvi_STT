import AVFoundation
import XCTest
@testable import Nuvi

final class ProbeTests: XCTestCase {
    func testHardTimeoutReturnsBeforeAStalledOperationIsReleased() async {
        let gate = ProbeAsyncGate()
        let finished = expectation(description: "timeout runner finished")

        let runner = Task {
            let outcome = await Probe.runWithTimeout(timeoutNanoseconds: 1_000_000) {
                await gate.wait()
            }
            finished.fulfill()
            return outcome
        }

        await fulfillment(of: [finished], timeout: 1)
        // Release the deliberately non-cooperative operation so the explicitly
        // owned task has a clean lifecycle before the test exits.
        await gate.open()

        let timedOut = await runner.value
        XCTAssertEqual(timedOut, .timedOut)
    }

    func testEngineTargetsIncludeParakeetWithoutConstructingRealEngines() {
        var constructed: [String] = []
        let targets = Probe.engineTargets(
            speechAnalyzerFactory: {
                constructed.append("SpeechAnalyzer")
                return ProbeEngineSpy()
            },
            whisperKitFactory: {
                constructed.append("WhisperKit")
                return ProbeEngineSpy()
            },
            parakeetFactory: {
                constructed.append("Parakeet")
                return ProbeEngineSpy()
            }
        )

        XCTAssertEqual(
            targets.map(\.name),
            ["SpeechAnalyzer", "WhisperKit", "Parakeet"]
        )
        XCTAssertTrue(constructed.isEmpty, "selection must not load or construct models")

        for target in targets {
            _ = target.makeEngine()
        }
        XCTAssertEqual(constructed, ["SpeechAnalyzer", "WhisperKit", "Parakeet"])
    }

    func testBoundedProbeStreamKeepsOldestBuffersAndCountsDrops() async throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let (stream, continuation) = Probe.makeBoundedAudioStream(capacity: 2)
        var droppedCount = 0

        XCTAssertEqual(
            Probe.yieldProbeBuffer(
                makeBuffer(format: format, value: 1),
                into: continuation,
                droppedCount: &droppedCount
            ),
            .enqueued
        )
        XCTAssertEqual(
            Probe.yieldProbeBuffer(
                makeBuffer(format: format, value: 2),
                into: continuation,
                droppedCount: &droppedCount
            ),
            .enqueued
        )
        XCTAssertEqual(
            Probe.yieldProbeBuffer(
                makeBuffer(format: format, value: 3),
                into: continuation,
                droppedCount: &droppedCount
            ),
            .dropped
        )

        continuation.finish()
        var values: [Float] = []
        for await buffer in stream {
            values.append(buffer.floatChannelData![0][0])
        }

        XCTAssertEqual(values, [1, 2])
        XCTAssertEqual(droppedCount, 1)
    }

    func testBoundedProbeStreamReportsTerminationWithoutCountingItAsDrop() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let (_, continuation) = Probe.makeBoundedAudioStream(capacity: 1)
        continuation.finish()
        var droppedCount = 0

        XCTAssertEqual(
            Probe.yieldProbeBuffer(
                makeBuffer(format: format, value: 1),
                into: continuation,
                droppedCount: &droppedCount
            ),
            .terminated
        )
        XCTAssertEqual(droppedCount, 0)
    }

    private func makeBuffer(format: AVAudioFormat, value: Float) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        buffer.frameLength = 1
        buffer.floatChannelData![0][0] = value
        return buffer
    }
}

private actor ProbeAsyncGate {
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}

private final class ProbeEngineSpy: TranscriptionEngine, @unchecked Sendable {
    var identifier: String { "probe-spy" }

    func prepare(locale: Locale) async throws {}

    func transcribe(
        _ audio: AsyncStream<AVAudioPCMBuffer>
    ) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}
