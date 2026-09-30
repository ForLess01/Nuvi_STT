import Foundation
import Combine

/// Drives the Appearance preview from the live microphone so the user can tune
/// the ferrofluid against their real voice. It owns a throwaway capture session
/// and only publishes the normalized level — the PCM stream is drained and
/// discarded (we don't transcribe here).
@MainActor
public final class FerrofluidMicProbe: ObservableObject {
    @Published public private(set) var level: Float = 0
    @Published public private(set) var spectrum: AudioSpectrum = .zero
    @Published public private(set) var active = false
    @Published public private(set) var denied = false

    private let capture: AudioCapturing
    private let control: SerialAudioCaptureControl
    private var sessionID: UUID?
    private var startupTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?

    public convenience init() {
        self.init(capture: AudioCaptureService())
    }

    internal init(capture: AudioCapturing) {
        self.capture = capture
        control = SerialAudioCaptureControl(capture: capture)
    }

    public func toggle() {
        sessionID != nil ? stop() : start()
    }

    public func start() {
        guard sessionID == nil else { return }
        let id = UUID()
        sessionID = id
        startupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let permitted = await capture.requestPermission()
            guard sessionID == id, !Task.isCancelled else { return }
            guard permitted else {
                denied = true
                sessionID = nil
                return
            }
            denied = false
            do {
                let stream = try await control.start(
                    id: id,
                    configuration: AudioCaptureConfiguration(duckOtherAudio: false),
                    onLevel: { [weak self] level in
                        Task { @MainActor in
                            guard let self, self.sessionID == id else { return }
                            self.level = level
                        }
                    },
                    onSpectrum: { [weak self] spectrum in
                        Task { @MainActor in
                            guard let self, self.sessionID == id else { return }
                            self.spectrum = spectrum
                            self.level = spectrum.level
                        }
                    }
                )
                guard sessionID == id, !Task.isCancelled else {
                    control.stop(id: id)
                    return
                }
                active = true
                // Drain and discard preview PCM; termination belongs to this ID.
                drainTask = Task { @MainActor [weak self] in
                    for await _ in stream {}
                    guard let self, self.sessionID == id else { return }
                    self.stop()
                }
            } catch {
                guard sessionID == id else { return }
                stop()
            }
        }
    }

    public func stop() {
        let id = sessionID
        sessionID = nil
        startupTask?.cancel()
        startupTask = nil
        if let id { control.stop(id: id) }
        drainTask?.cancel()
        drainTask = nil
        spectrum = .zero
        level = 0
        active = false
    }
}
