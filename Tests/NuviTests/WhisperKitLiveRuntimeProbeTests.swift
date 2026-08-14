import AVFoundation
import XCTest
@testable import Nuvi

final class WhisperKitLiveRuntimeProbeTests: XCTestCase {
    func testDownloadedWhisperModelsProduceLivePartials() async throws {
        guard ProcessInfo.processInfo.environment["NUVI_RUN_WHISPER_LIVE_PROBE"] == "1" else {
            throw XCTSkip("Runtime probe only")
        }

        for modelID in ["openai_whisper-tiny", "openai_whisper-base"] {
            let result = try await probe(modelID: modelID)
            XCTAssertFalse(result.partials.isEmpty, "Expected a live partial from \(modelID)")
            XCTAssertFalse(result.final.isEmpty, "Expected a final result from \(modelID)")
        }
    }

    private func probe(modelID: String) async throws -> (partials: [String], final: String) {
        let engine = WhisperKitEngine(modelName: modelID)
        try await engine.prepare(locale: Locale(identifier: "en-US"))

        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(
                ".build/checkouts/argmax-oss-swift/Tests/WhisperKitTests/Resources/jfk.wav"
            )
        let file = try AVAudioFile(forReading: url)
        let (audio, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        let feeder = Task {
            while file.framePosition < file.length {
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
            case .partial(let text): partials.append(text)
            case .final(let text): final = text
            }
        }
        try await feeder.value
        FileHandle.standardError.write(
            Data("WHISPER_LIVE_PROBE model=\(modelID) partials=\(partials) final=\(final)\n".utf8)
        )
        return (partials, final)
    }
}
