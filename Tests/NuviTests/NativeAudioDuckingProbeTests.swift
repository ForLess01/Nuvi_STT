import XCTest
import AVFoundation
@testable import Nuvi

/// Opt-in hardware smoke test. It proves that the production VPIO path can
/// start, deliver frames, and clean up on this Mac; it cannot prove acoustic
/// attenuation of another application's output.
final class NativeAudioDuckingProbeTests: XCTestCase {
    func testPreauthorizedNativeDuckingCaptureDeliversFrames() async throws {
        guard ProcessInfo.processInfo.environment["NUVI_RUN_NATIVE_DUCKING_PROBE"] == "1" else {
            throw XCTSkip("Native ducking probe is opt-in")
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw XCTSkip("Native ducking probe requires preauthorized microphone access and never requests permission")
        }

        let capture = AudioCaptureService()
        let counter = FrameCounter()
        let outputBefore = AudioInputDevice.currentOutputState()
        var consumer: Task<Void, Never>?
        defer {
            capture.stop()
            consumer?.cancel()
        }

        let stream = try capture.start(
            configuration: AudioCaptureConfiguration(duckOtherAudio: true)
        )
        consumer = Task {
            for await buffer in stream {
                await counter.add(buffer.frameLength)
            }
        }

        try await Task.sleep(nanoseconds: 250_000_000)
        capture.stop()
        await consumer?.value

        let frames = await counter.value
        let outputAfter = AudioInputDevice.currentOutputState()
        let diagnostics = try XCTUnwrap(capture.lastDiagnostics)
        XCTAssertEqual(diagnostics.requestedBackend, .voiceProcessingIO)
        XCTAssertEqual(diagnostics.effectiveBackend, .voiceProcessingIO)
        XCTAssertTrue(diagnostics.cleanupComplete)
        if let outputBefore, let outputAfter {
            XCTAssertEqual(outputAfter.deviceID, outputBefore.deviceID)
            XCTAssertEqual(outputAfter.volume, outputBefore.volume)
            XCTAssertEqual(outputAfter.muted, outputBefore.muted)
        }

        print(
            "NATIVE_DUCKING_PROBE setup=ok frames=\(frames) " +
            "output_device=\(outputAfter?.deviceID as Any) " +
            "volume_before=\(outputBefore?.volume as Any) " +
            "volume_after=\(outputAfter?.volume as Any) " +
            "muted_before=\(outputBefore?.muted as Any) " +
            "muted_after=\(outputAfter?.muted as Any) " +
            "physical_attenuation=not_proven"
        )
        XCTAssertGreaterThan(frames, 0, "The VPIO probe started but delivered no microphone frames")
    }
}

private actor FrameCounter {
    private(set) var value: AVAudioFrameCount = 0

    func add(_ frames: AVAudioFrameCount) {
        value += frames
    }
}
