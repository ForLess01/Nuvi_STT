import MetalKit
import QuartzCore

/// Drives the ferrofluid shader at 60fps. Eases toward the target `level` so the
/// blob moves like a fluid. `settings` are live-tunable from the Settings UI.
/// When `simulate` is on (Settings preview), it animates a synthetic level so
/// the spikes move without a microphone.
final class FerrofluidRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState?
    private let startTime = CACurrentMediaTime()

    var level: Float = 0
    var settings: FerrofluidSettings = .default
    var simulate: Bool = false

    private var smoothed: Float = 0

    private struct Uniforms {
        var time: Float
        var level: Float
        var resolution: SIMD2<Float>
        var coreSize: Float
        var reach: Float
        var spikiness: Float
        var viscosity: Float
        var speed: Float
        var spikeCount: Float
    }

    init?(mtkView: MTKView) {
        guard let device = mtkView.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            return nil
        }
        self.device = device
        self.queue = queue
        super.init()

        mtkView.device = device
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = true
        mtkView.layer?.isOpaque = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = false
        mtkView.preferredFramesPerSecond = 60

        do {
            try buildPipeline(view: mtkView)
        } catch {
            NSLog("Nuvi: failed to build ferrofluid pipeline: \(error)")
            return nil
        }
    }

    private func buildPipeline(view: MTKView) throws {
        let library = try device.makeLibrary(source: FerrofluidShaderSource, options: nil)

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "nuvi_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "nuvi_fragment")

        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = view.colorPixelFormat
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .sourceAlpha
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pipeline,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer() else { return }

        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        let time = Float(CACurrentMediaTime() - startTime)
        let target = simulate ? (0.45 + 0.45 * (0.5 + 0.5 * sin(time * 3.1))) : level
        smoothed += (target - smoothed) * 0.22

        var uniforms = Uniforms(
            time: time,
            level: smoothed,
            resolution: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            coreSize: settings.coreSize,
            reach: settings.reach,
            spikiness: settings.spikiness,
            viscosity: settings.viscosity,
            speed: settings.speed,
            spikeCount: settings.spikeCount
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()

        command.present(drawable)
        command.commit()
    }
}
