import Foundation
import AVFoundation

/// Headless verification: feed an audio file through each engine and print what
/// it returns. Run with:  Nuvi --probe /path/to/audio.{caf,wav,m4a}
/// Lets us confirm SpeechAnalyzer and WhisperKit actually transcribe on this Mac,
/// independent of the GUI, mic, hotkeys, and pasting.
enum Probe {
    static func run(path: String, localeID: String) async {
        let url = URL(fileURLWithPath: path)
        let locale = Locale(identifier: localeID)
        print("== Nuvi probe ==\nfile: \(path)\nlocale: \(localeID)\n")

        await testWithTimeout("SpeechAnalyzer", engine: SpeechAnalyzerEngine(), url: url, locale: locale)
        await testWithTimeout("WhisperKit", engine: WhisperKitEngine(), url: url, locale: locale)

        print("\n== probe done ==")
    }

    private static func testWithTimeout(_ name: String,
                                        engine: TranscriptionEngine,
                                        url: URL,
                                        locale: Locale) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await test(name, engine: engine, url: url, locale: locale)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                print("[\(name)] TIMEOUT after 30s\n")
            }
            await group.next()
            group.cancelAll()
        }
    }

    private static func test(_ name: String, engine: TranscriptionEngine,
                             url: URL, locale: Locale) async {
        do {
            print("[\(name)] preparing…")
            try await engine.prepare(locale: locale)
            print("[\(name)] feeding audio…")

            let stream = try makeStream(url)
            var finalText = ""
            for try await event in engine.transcribe(stream) {
                switch event {
                case .partial(let t): finalText = t
                case .final(let t) where !t.isEmpty: finalText = t
                case .final: break
                }
            }
            print("[\(name)] RESULT: \"\(finalText)\"\n")
        } catch {
            print("[\(name)] ERROR: \(error)\n")
        }
    }

    private static func makeStream(_ url: URL) throws -> AsyncStream<AVAudioPCMBuffer> {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()

        let chunk: AVAudioFrameCount = 4096
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
            try file.read(into: buffer)
            if buffer.frameLength == 0 { break }
            continuation.yield(buffer)
        }
        continuation.finish()
        return stream
    }
}
