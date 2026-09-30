import Foundation
import AVFoundation

/// Enqueues requests in main-actor order, but runs every blocking native call
/// on one serial control queue. Cancellation never abandons native ownership.
internal final class SerialAudioCaptureControl: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "com.nuvi.audio.native-control")
    private let capture: AudioCapturing
    // Accessed only on the native-control queue, not on the caller's actor.
    private var activeID: UUID?

    init(capture: AudioCapturing) {
        self.capture = capture
    }

    @MainActor
    func start(
        id: UUID,
        configuration: AudioCaptureConfiguration,
        onLevel: @escaping @Sendable (Float) -> Void,
        onSpectrum: @escaping @Sendable (AudioSpectrum) -> Void
    ) async throws -> AsyncStream<AVAudioPCMBuffer> {
        try Task.checkCancellation()
        let enqueued = DispatchTime.now().uptimeNanoseconds
        return try await withCheckedThrowingContinuation { continuation in
            Self.queue.async { [self] in
                AudioPhaseTiming.record("start_queue_wait", owner: id.uuidString, since: enqueued)
                let timing = AudioPhaseTiming("capture_start", owner: id.uuidString)
                defer { timing.finish() }
                // A replacement must finish any previous teardown first, even
                // if a previous task completed without an explicit PTT stop.
                if activeID != nil { capture.stop() }
                activeID = id
                capture.onLevel = onLevel
                capture.onSpectrum = onSpectrum
                do {
                    continuation.resume(returning: try capture.start(configuration: configuration))
                } catch {
                    capture.stop()
                    activeID = nil
                    capture.onLevel = nil
                    capture.onSpectrum = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @MainActor
    func stop(id: UUID) {
        let enqueued = DispatchTime.now().uptimeNanoseconds
        Self.queue.async { [self] in
            // Old task completion/cancellation must never stop its successor.
            guard activeID == id else { return }
            AudioPhaseTiming.record("stop_queue_wait", owner: id.uuidString, since: enqueued)
            AudioPhaseTiming.measure("capture_stop", owner: id.uuidString) { capture.stop() }
            activeID = nil
            capture.onLevel = nil
            capture.onSpectrum = nil
        }
    }

    deinit {
        // Retain the underlying service through final off-main teardown; its
        // native-resource-owning deinitializer must not run on the UI actor.
        let capture = capture
        Self.queue.async { capture.stop() }
    }
}
