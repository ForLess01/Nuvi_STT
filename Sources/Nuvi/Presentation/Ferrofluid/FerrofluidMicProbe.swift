import Foundation
import Combine

/// Drives the Appearance preview from the live microphone so the user can tune
/// the ferrofluid against their real voice. It owns a throwaway capture session
/// and only publishes the normalized level — the PCM stream is drained and
/// discarded (we don't transcribe here).
@MainActor
public final class FerrofluidMicProbe: ObservableObject {
    @Published public private(set) var level: Float = 0
    @Published public private(set) var active = false
    @Published public private(set) var denied = false

    private let capture = AudioCaptureService()
    private var drainTask: Task<Void, Never>?

    public init() {}

    public func toggle() {
        active ? stop() : start()
    }

    public func start() {
        Task { @MainActor in
            guard await capture.requestPermission() else {
                denied = true
                active = false
                return
            }
            denied = false
            capture.onLevel = { [weak self] lvl in
                Task { @MainActor in self?.level = lvl }
            }
            do {
                let stream = try capture.start()
                active = true
                // Drain the PCM stream so it doesn't accumulate in memory.
                drainTask = Task { for await _ in stream {} }
            } catch {
                active = false
            }
        }
    }

    public func stop() {
        capture.stop()
        drainTask?.cancel()
        drainTask = nil
        level = 0
        active = false
    }
}
