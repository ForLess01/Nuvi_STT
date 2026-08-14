import AVFoundation
import XCTest
@testable import Nuvi

final class ParakeetLiveRuntimeProbeTests: XCTestCase {
    func testKnownSpeechProducesLivePartials() async throws {
        guard ProcessInfo.processInfo.environment["NUVI_RUN_LIVE_PROBE"] == "1" else {
            throw XCTSkip("Runtime probe only")
        }

        let engine = ParakeetEngine(modelId: "parakeet-tdt-0.6b-v3")
        try await engine.prepare(locale: Locale(identifier: "en-US"))

        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/checkouts/argmax-oss-swift/Tests/WhisperKitTests/Resources/jfk.wav")
        let file = try AVAudioFile(forReading: url)
        let (audio, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()

        let feeder = Task {
            let totalFrames = AVAudioFramePosition(file.length)
            while file.framePosition < totalFrames {
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat,
                    frameCapacity: 1_600
                ) else { break }
                try file.read(into: buffer)
                guard buffer.frameLength > 0 else { break }
                continuation.yield(buffer)
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            continuation.finish()
        }

        var partials: [String] = []
        var final = ""
        for try await event in engine.transcribe(audio, reportingPartials: true) {
            switch event {
            case .partial(let text):
                partials.append(text)
                FileHandle.standardError.write(Data("partial=\(text)\n".utf8))
            case .final(let text):
                final = text
                FileHandle.standardError.write(Data("final=\(text)\n".utf8))
            }
        }
        try await feeder.value

        print("LIVE_PROBE partials=\(partials) final=\(final)")
        XCTAssertFalse(partials.isEmpty)
        XCTAssertFalse(final.isEmpty)
    }
}
