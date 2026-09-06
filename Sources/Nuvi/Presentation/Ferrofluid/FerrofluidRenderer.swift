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
    var spectrum: AudioSpectrum = .zero
    var settings: FerrofluidSettings = .default
    var simulate: Bool = false

    private var smoothed: Float = 0
    private var smoothedBass: Float = 0
    private var smoothedMid: Float = 0
    private var smoothedTreble: Float = 0

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
        var fluidR: Float
        var fluidG: Float
        var fluidB: Float
        var bgR: Float
        var bgG: Float
        var bgB: Float
        var bass: Float
        var mid: Float
        var treble: Float
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
        let sens = max(0.1, settings.sensitivity)
        let targetLevel: Float
        let targetBass: Float
        let targetMid: Float
        let targetTreble: Float

        if simulate {
            let wave = 0.5 + 0.5 * sin(time * 3.1)
            targetLevel = min(1.0, (0.45 + 0.45 * wave) * sens)
            targetBass = min(1.0, (0.40 + 0.40 * (0.5 + 0.5 * sin(time * 2.2))) * sens)
            targetMid = min(1.0, (0.35 + 0.35 * (0.5 + 0.5 * sin(time * 4.1 + 1.0))) * sens)
            targetTreble = min(1.0, (0.30 + 0.30 * (0.5 + 0.5 * sin(time * 7.5 + 2.0))) * sens)
        } else {
            targetLevel = min(1.0, level * sens)
            if spectrum != .zero {
                targetBass = min(1.0, spectrum.bass * sens)
                targetMid = min(1.0, spectrum.mid * sens)
                targetTreble = min(1.0, spectrum.treble * sens)
            } else {
                targetBass = min(1.0, level * 0.9 * sens)
                targetMid = min(1.0, level * 0.7 * sens)
                targetTreble = min(1.0, level * 0.5 * sens)
            }
        }

        // Bass: heavier mass, slower decay
        let bassCoeff: Float = targetBass > smoothedBass ? 0.25 : 0.08
        smoothedBass += (targetBass - smoothedBass) * bassCoeff

        // Mid: moderate fluid damping
        let midCoeff: Float = targetMid > smoothedMid ? 0.35 : 0.18
        smoothedMid += (targetMid - smoothedMid) * midCoeff

        // Treble: fast, sharp reaction for surface micro-spikes
        let trebleCoeff: Float = targetTreble > smoothedTreble ? 0.65 : 0.35
        smoothedTreble += (targetTreble - smoothedTreble) * trebleCoeff

        // Level: overall fluid volume easing
        let levelCoeff: Float = targetLevel > smoothed ? 0.28 : 0.18
        smoothed += (targetLevel - smoothed) * levelCoeff

        var uniforms = Uniforms(
            time: time,
            level: smoothed,
            resolution: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            coreSize: settings.coreSize,
            reach: settings.reach,
            spikiness: settings.spikiness,
            viscosity: settings.viscosity,
            speed: settings.speed,
            spikeCount: settings.spikeCount,
            fluidR: settings.fluidColor.r,
            fluidG: settings.fluidColor.g,
            fluidB: settings.fluidColor.b,
            bgR: settings.backgroundColor.r,
            bgG: settings.backgroundColor.g,
            bgB: settings.backgroundColor.b,
            bass: smoothedBass,
            mid: smoothedMid,
            treble: smoothedTreble
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()

        command.present(drawable)
        command.commit()
    }
}
