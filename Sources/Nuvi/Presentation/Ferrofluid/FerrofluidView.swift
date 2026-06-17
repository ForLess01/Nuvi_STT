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
        let view = MTKView()
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
