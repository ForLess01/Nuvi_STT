import AVFoundation
import Foundation

/// Model-free ownership boundaries used by the concrete engine adapters.
enum SpeechStreamSessions {
    static func withCleanup<Value>(
        operation: () async throws -> Value,
        cleanup: () async -> Void
    ) async throws -> Value {
        let result: Result<Value, Error>
        do { result = .success(try await operation()) }
        catch { result = .failure(error) }
        // One exit path ensures cleanup is also joined on failure/cancellation.
        await cleanup()
        return try result.get()
    }

    static func whisper(
        audio: AsyncStream<AVAudioPCMBuffer>,
        minimumSamples: Int = 32_000,
        cadence: Int,
        windowCapacity: Int = WhisperKitEngine.liveWindowSamples,
        maximumSamples: Int = 16_000 * 10 * 60,
        decode: @escaping @Sendable ([Float]) async throws -> String
    ) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let intake = WhisperIntake(windowCapacity: windowCapacity, maximumSamples: maximumSamples)
                // Notifications contain no audio. A busy decoder keeps only one
                // pending refresh, while intake continues draining the capture queue.
                let (refreshes, refresh) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                let producer = Task {
                    defer { refresh.finish() }
                    var nextHypothesisAt = minimumSamples
                    for await buffer in audio {
                        try Task.checkCancellation()
                        let count = try await intake.append(buffer)
                        if count >= nextHypothesisAt {
                            refresh.yield(())
                            nextHypothesisAt = count + cadence
                        }
                    }
                    try Task.checkCancellation()
                }
                do {
                    try await withTaskCancellationHandler {
                        try await withCleanup(operation: {
                            var lastPartial = ""
                            for await _ in refreshes {
                                try Task.checkCancellation()
                                let text = try await decode(await intake.windowSnapshot())
                                if !text.isEmpty, text != lastPartial {
                                    continuation.yield(.partial(text))
                                    lastPartial = text
                                }
                            }
                            try await producer.value
                            try Task.checkCancellation()
                            let samples = await intake.finalSamples()
                            guard !samples.isEmpty else { throw NuviError.noAudioReceived }
                            let final = try await decode(samples)
                            try Task.checkCancellation()
                            continuation.yield(.final(final))
                        }, cleanup: {
                            producer.cancel()
                            _ = await producer.result
                        })
                    } onCancel: {
                        producer.cancel()
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: WhisperKitEngine.normalizedTranscriptionError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Owns conversion and audio storage independently of inference. Only a rolling
/// snapshot is copied per partial; complete audio is handed off after intake ends.
private actor WhisperIntake {
    private let converter: BufferConverter
    private let maximumSamples: Int
    private var samples: [Float] = []
    private var window: RollingAudioWindow

    init(windowCapacity: Int, maximumSamples: Int) {
        self.maximumSamples = maximumSamples
        window = RollingAudioWindow(capacity: windowCapacity)
        converter = BufferConverter(targetFormat: AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!)
    }

    func append(_ buffer: AVAudioPCMBuffer) throws -> Int {
        guard let converted = converter.convert(buffer),
              let channel = converted.floatChannelData else { return samples.count }
        let source = UnsafeBufferPointer(start: channel[0], count: Int(converted.frameLength))
        guard samples.count + source.count <= maximumSamples else {
            throw TranscriptionError.underlying("WhisperKit input exceeded 10 minute limit")
        }
        samples.append(contentsOf: source)
        window.append(contentsOf: source)
        return samples.count
    }

    func windowSnapshot() -> [Float] { window.snapshot() }
    func finalSamples() -> [Float] { samples }
}
