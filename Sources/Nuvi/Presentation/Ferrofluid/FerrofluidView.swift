import SwiftUI
import MetalKit

/// SwiftUI bridge for the Metal ferrofluid. Feeds the live audio level and the
/// tunable look into the renderer. Set `simulate` for the Settings preview so it
/// animates without a microphone.
struct FerrofluidView: NSViewRepresentable {
    var level: Float
    var settings: FerrofluidSettings
    var simulate: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        let view = AutoPauseMTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.layer?.isOpaque = false
        let renderer = FerrofluidRenderer(mtkView: view)
        view.delegate = renderer
        context.coordinator.renderer = renderer
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.renderer?.level = level
        context.coordinator.renderer?.settings = settings
        context.coordinator.renderer?.simulate = simulate
    }

    final class Coordinator {
        var renderer: FerrofluidRenderer?
    }
}

/// An `MTKView` that pauses its render loop whenever its window isn't actually
/// visible on screen. Without this the ferrofluid keeps drawing at 60fps even
/// while the pill is hidden (`orderOut` doesn't pause it) — a constant battery
/// and GPU drain. Resumes the instant the window becomes visible again.
final class AutoPauseMTKView: MTKView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(updatePauseState),
                name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        updatePauseState()
    }

    @objc private func updatePauseState() {
        guard let window, window.occlusionState.contains(.visible) else {
            isPaused = true
            return
        }
        isPaused = false
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
