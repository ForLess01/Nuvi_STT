import AppKit
import CoreGraphics

/// Renders Nuvi's identity mark as a static image: the same metaball + fbm field
/// as the Metal shader and the app-icon generator, so the menu bar, app icon and
/// live visualizer all read as one liquid identity. Classic look — black
/// ferrofluid inside a glowing white circular chamber.
enum FerrofluidBlobImage {

    // MARK: - Noise field (mirrors FerrofluidShader / scripts/make-icon.swift)

    private static func fract(_ x: Double) -> Double { x - floor(x) }

    private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    private static func hash21(_ x: Double, _ y: Double) -> Double {
        let px = fract(x * 127.1 + y * 311.7)
        let py = fract(x * 269.5 + y * 183.3)
        var r = fract((px + py) * 43758.5453)
        r = fract(r + px * py)
        return r
    }

    private static func vnoise(_ x: Double, _ y: Double) -> Double {
        let ix = floor(x), iy = floor(y)
        let fx = x - ix, fy = y - iy
        let a = hash21(ix, iy), b = hash21(ix + 1, iy)
        let c = hash21(ix, iy + 1), d = hash21(ix + 1, iy + 1)
        let ux = fx * fx * (3 - 2 * fx), uy = fy * fy * (3 - 2 * fy)
        return (a * (1 - ux) + b * ux) * (1 - uy) + (c * (1 - ux) + d * ux) * uy
    }

    private static func fbm(_ x0: Double, _ y0: Double) -> Double {
        var v = 0.0, a = 0.5, x = x0, y = y0
        for _ in 0..<5 { v += a * vnoise(x, y); x *= 2.02; y *= 2.02; a *= 0.5 }
        return v
    }

    private struct Sat { let cx: Double; let cy: Double; let r: Double }

    private static let level = 0.55, coreSize = 0.20, reach = 0.58
    private static let spikiness = 3.0, viscosity = 0.038, spikeCount = 9

    private static let satellites: [Sat] = (0..<spikeCount).map { i in
        let fi = Double(i)
        let seed = hash21(fi, 1.0)
        let ang = fi * 2.39996
        let rad = coreSize * 0.55 + (reach * level) * (0.4 + 0.6 * vnoise(fi, 0))
        let ri = (0.03 + 0.06 * level) * (0.55 + 0.9 * seed)
        return Sat(cx: rad * cos(ang), cy: rad * sin(ang), r: ri)
    }

    private static func metaball(_ px: Double, _ py: Double, _ cx: Double, _ cy: Double, _ r: Double) -> Double {
        let dx = px - cx, dy = py - cy
        return (r * r) / (dx * dx + dy * dy + 1e-4)
    }

    /// Ink coverage 0...1 at centered uv (~[-1,1]).
    private static func ink(_ ux: Double, _ uy: Double) -> Double {
        let qx = fbm(ux * 2.2, uy * 2.2)
        let qy = fbm(ux * 2.2 + 5.2, uy * 2.2 + 1.3)
        let px = ux + (0.08 + 0.14 * level) * (qx - 0.5)
        let py = uy + (0.08 + 0.14 * level) * (qy - 0.5)

        var field = metaball(px, py, 0, 0, coreSize + 0.06 * level)
        for s in satellites { field += metaball(px, py, s.cx, s.cy, s.r) }

        var ridge = 1 - abs(2 * fbm(px * (Double(spikeCount) + 2), py * (Double(spikeCount) + 2)) - 1)
        ridge = pow(max(0, min(1, ridge)), max(1, spikiness))
        field += ridge * max(0, min(1, field)) * (0.3 + 1.6 * level)

        let w = 0.16 + viscosity * 4.5
        var k = smoothstep(1 - w, 1 + w, field)
        k *= smoothstep(1.30, 0.95, sqrt(ux * ux + uy * uy))
        return k
    }

    // MARK: - Menu bar image

    /// Round chamber badge for the menu bar: a glowing white disc with the black
    /// ferrofluid blob, transparent outside the disc. Not a template image — it's
    /// a deliberate white/black mark, not a tintable glyph.
    static func menuBarImage(pointSize: CGFloat = 18, scale: CGFloat = 2) -> NSImage {
        let pixels = max(1, Int(pointSize * scale))
        let cg = renderBadge(pixels: pixels)
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(width: pointSize, height: pointSize)
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
        image.addRepresentation(rep)
        image.isTemplate = false
        return image
    }

    // MARK: - Menu bar "N" mark

    /// Rounded-square tile with an "N" made of ferrofluid: the letterform
    /// silhouette grown organic, liquid spikes along its edges. Light tile so the
    /// black fluid reads; not a template image.
    static func menuBarNImage(pointSize: CGFloat = 18, scale: CGFloat = 2) -> NSImage {
        let pixels = max(1, Int(pointSize * scale))
        let cg = renderNBadge(pixels: pixels)
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(width: pointSize, height: pointSize)
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
        image.addRepresentation(rep)
        image.isTemplate = false
        return image
    }

    /// Distance from point (px,py) to the segment a→b.
    private static func sdSegment(_ px: Double, _ py: Double,
                                  _ ax: Double, _ ay: Double,
                                  _ bx: Double, _ by: Double) -> Double {
        let pax = px - ax, pay = py - ay
        let bax = bx - ax, bay = by - ay
        let h = max(0, min(1, (pax * bax + pay * bay) / (bax * bax + bay * bay)))
        let dx = pax - bax * h, dy = pay - bay * h
        return (dx * dx + dy * dy).squareRoot()
    }

    private static func renderNBadge(pixels n: Int) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8,
                            bytesPerRow: n * 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let ptr = ctx.data!.bindMemory(to: UInt8.self, capacity: n * n * 4)
        let S = Double(n)

        // Rounded-square tile in pixel space.
        let inset = S * 0.05
        let half = (S - 2 * inset) / 2
        let cornerR = (S - 2 * inset) * 0.30
        let cx0 = S / 2, cy0 = S / 2

        // N geometry in centered units (-1...1), scaled by `half`.
        let topY = 0.58, botY = -0.58, lX = -0.40, rX = 0.40
        let strokeW = 0.205       // stroke half-width
        let aa = 1.3 / half       // ~1px antialias in centered units

        for y in 0..<n {
            for x in 0..<n {
                let fx = Double(x) + 0.5, fy = Double(y) + 0.5

                // Squircle coverage.
                let qx = abs(fx - cx0) - (half - cornerR)
                let qy = abs(fy - cy0) - (half - cornerR)
                let outside = (pow(max(qx, 0), 2) + pow(max(qy, 0), 2)).squareRoot()
                    + min(max(qx, qy), 0) - cornerR
                let coverage = smoothstep(1.0, -1.0, outside)

                var lum = 0.0, alpha = 0.0
                if coverage > 0 {
                    let cx = (fx - cx0) / half
                    let cy = (fy - cy0) / half

                    // Distance to the N skeleton (three strokes).
                    let d = min(sdSegment(cx, cy, lX, botY, lX, topY),
                                min(sdSegment(cx, cy, lX, topY, rX, botY),
                                    sdSegment(cx, cy, rX, botY, rX, topY)))
                    let sdN = d - strokeW

                    // Ferrofluid: organic liquid spikes grown along the edge.
                    let ridge = 1 - abs(2 * fbm(cx * 7.0 + 2.0, cy * 7.0 - 1.0) - 1)
                    let spike = pow(max(0, ridge), 1.5) * 0.17
                    let band = smoothstep(0.0, 0.05, sdN) * smoothstep(0.32, 0.10, sdN)
                    let wobble = (fbm(cx * 3.0, cy * 3.0) - 0.5) * 0.03
                    let surface = sdN - spike * band - wobble
                    let inkN = smoothstep(aa, -aa, surface)

                    // Light tile with a soft rim, black fluid on top.
                    let dist = (cx * cx + cy * cy).squareRoot()
                    var bg = 0.965
                    bg -= smoothstep(0.75, 1.15, dist) * 0.07
                    lum = bg * (1 - inkN) + 0.04 * inkN
                    alpha = coverage
                }

                let i = (y * n + x) * 4
                let p = UInt8(max(0, min(255, lum * alpha * 255)))
                ptr[i + 0] = p
                ptr[i + 1] = p
                ptr[i + 2] = p
                ptr[i + 3] = UInt8(max(0, min(255, alpha * 255)))
            }
        }
        return ctx.makeImage()!
    }

    private static func renderBadge(pixels n: Int) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8,
                            bytesPerRow: n * 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let ptr = ctx.data!.bindMemory(to: UInt8.self, capacity: n * n * 4)
        let S = Double(n)
        let uvScale = 1.6  // fill the disc with the blob

        for y in 0..<n {
            for x in 0..<n {
                let fx = Double(x) + 0.5, fy = Double(y) + 0.5
                let cx = (fx / S * 2 - 1)
                let cy = (fy / S * 2 - 1)
                let dist = (cx * cx + cy * cy).squareRoot()

                // Soft round disc; transparent outside.
                let disc = smoothstep(1.0, 0.93, dist)
                var lum = 0.0, alpha = 0.0
                if disc > 0 {
                    var base = 0.97
                    base -= smoothstep(0.82, 1.0, dist) * 0.10   // chamber rim shade
                    let k = ink(cx * uvScale, cy * uvScale)
                    lum = base * (1 - k) + 0.04 * k
                    alpha = disc
                }

                let i = (y * n + x) * 4
                let p = UInt8(max(0, min(255, lum * alpha * 255)))
                ptr[i + 0] = p
                ptr[i + 1] = p
                ptr[i + 2] = p
                ptr[i + 3] = UInt8(max(0, min(255, alpha * 255)))
            }
        }
        return ctx.makeImage()!
    }
}
