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

    // 2nd-order harmonic spring-damper physical state (mass + viscous fluid damping)
    private var levelPos: Float = 0
    private var levelVel: Float = 0

    private var bassPos: Float = 0
    private var bassVel: Float = 0

    private var midPos: Float = 0
    private var midVel: Float = 0

    private var treblePos: Float = 0
    private var trebleVel: Float = 0

    private var lastFrameTime: Double = 0

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
        var style: Float
        var coreSens: Float
        var dropletSens: Float
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

        let currentRealTime = CACurrentMediaTime()
        let dt: Float
        if lastFrameTime > 0 {
            dt = Float(min(0.04, max(0.001, currentRealTime - lastFrameTime)))
        } else {
            dt = 1.0 / 60.0
        }
        lastFrameTime = currentRealTime

        // 2nd-order physical spring-damper integrator (symplectic Euler)
        // Eliminates impulse jerk; yields physical fluid inertia, mass, and viscous rebound
        func stepSpring(pos: inout Float, vel: inout Float, target: Float, omega: Float, damping: Float) {
            let effectiveDamping = target < pos ? damping * 1.12 : damping
            let k = omega * omega
            let c = 2.0 * effectiveDamping * omega
            let accel = -k * (pos - target) - c * vel
            vel += accel * dt
            pos += vel * dt
            if pos < 0.0001 && target <= 0.0001 && abs(vel) < 0.001 {
                pos = 0
                vel = 0
            }
        }

        // Bass: heavy fluid mass (omega = 15.0, damping = 0.94)
        stepSpring(pos: &bassPos, vel: &bassVel, target: targetBass, omega: 15.0, damping: 0.94)

        // Mid: vocal core resonance (omega = 20.0, damping = 0.88 - organic droplet bounce)
        stepSpring(pos: &midPos, vel: &midVel, target: targetMid, omega: 20.0, damping: 0.88)

        // Treble: surface harmonic agility (omega = 24.0, damping = 0.96 - zero jitter)
        stepSpring(pos: &treblePos, vel: &trebleVel, target: targetTreble, omega: 24.0, damping: 0.96)

        // Level: overall fluid breathing envelope (omega = 17.0, damping = 1.0)
        stepSpring(pos: &levelPos, vel: &levelVel, target: targetLevel, omega: 17.0, damping: 1.0)

        var uniforms = Uniforms(
            time: time,
            level: levelPos,
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
            bass: bassPos,
            mid: midPos,
            treble: treblePos,
            style: settings.style == .spikes ? 1.0 : 0.0,
            coreSens: max(0.1, settings.coreSensitivity),
            dropletSens: max(0.1, settings.dropletSensitivity)
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()

        command.present(drawable)
        command.commit()
    }
}
