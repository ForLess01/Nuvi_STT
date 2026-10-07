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
        let outputBefore = AudioInputDevice.currentOutputState()
        var consumer: Task<Void, Never>?
        defer {
            capture.stop()
            consumer?.cancel()
        }

        for cycle in 1...2 {
            let counter = FrameCounter()
            let stream = try capture.start(
                configuration: AudioCaptureConfiguration(duckOtherAudio: true)
            )
            consumer = Task {
                for await buffer in stream {
                    await counter.add(buffer.frameLength)
                }
            }

            // VPIO can need longer than 250 ms to prime after reinitialization.
            // Keep this authorized hardware smoke check bounded, without
            // persisting audio or asserting acoustic attenuation.
            try await Task.sleep(nanoseconds: 1_500_000_000)
            capture.stop()
            await consumer?.value
            consumer = nil

            let frames = await counter.value
            let outputAfter = AudioInputDevice.currentOutputState()
            let diagnostics = try XCTUnwrap(capture.lastDiagnostics)
            XCTAssertEqual(diagnostics.requestedBackend, .voiceProcessingIO)
            XCTAssertEqual(diagnostics.effectiveBackend, .voiceProcessingIO)
            XCTAssertEqual(capture.lastCleanupStatus.stop, noErr)
            XCTAssertNil(capture.lastCleanupStatus.uninitialize)
            XCTAssertNil(capture.lastCleanupStatus.dispose)
            XCTAssertFalse(diagnostics.cleanupComplete)
            if let outputBefore, let outputAfter {
                XCTAssertEqual(outputAfter.deviceID, outputBefore.deviceID)
                XCTAssertEqual(outputAfter.volume, outputBefore.volume)
                XCTAssertEqual(outputAfter.muted, outputBefore.muted)
            }

            print("NATIVE_DUCKING_CAPACITY cycle=\(cycle) maximum_frames=\(diagnostics.maximumFramesPerSlice) stopped=confirmed initialized_reuse=true")
            print(
                "NATIVE_DUCKING_PROBE cycle=\(cycle) setup=ok frames=\(frames) " +
                "output_device=\(outputAfter?.deviceID as Any) " +
                "volume_before=\(outputBefore?.volume as Any) " +
                "volume_after=\(outputAfter?.volume as Any) " +
                "muted_before=\(outputBefore?.muted as Any) " +
                "muted_after=\(outputAfter?.muted as Any) " +
                "physical_attenuation=not_proven"
            )
            XCTAssertGreaterThan(frames, 0, "VPIO cycle \(cycle) started but delivered no microphone frames")
        }
    }
}

private actor FrameCounter {
    private(set) var value: AVAudioFrameCount = 0

    func add(_ frames: AVAudioFrameCount) {
        value += frames
    }
}
