#!/usr/bin/env swift
//
// Generates Nuvi's app icon: a white squircle with a black FERROFLUID blob.
// The blob is rendered per-pixel with the same metaball + fbm-noise field as the
// Metal shader, so it reads as an organic LIQUID (merging droplets, irregular
// fingers) rather than a regular star. Rendered at 1024 then downscaled.
//
import AppKit
import CoreGraphics
import Foundation

let outDir = "build/Nuvi.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// ---- Noise (mirrors the shader) ----
func fract(_ x: Double) -> Double { x - floor(x) }
func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = max(0, min(1, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)
}
func hash21(_ x: Double, _ y: Double) -> Double {
    var px = fract(x * 0.1031), py = fract(y * 0.1030)   // stable-ish
    px = fract(x * 127.1 + y * 311.7)
    py = fract(x * 269.5 + y * 183.3)
    var r = fract((px + py) * 43758.5453)
    r = fract(r + (px * py))
    return r
}
func vnoise(_ x: Double, _ y: Double) -> Double {
    let ix = floor(x), iy = floor(y)
    let fx = x - ix, fy = y - iy
    let a = hash21(ix, iy)
    let b = hash21(ix + 1, iy)
    let c = hash21(ix, iy + 1)
    let d = hash21(ix + 1, iy + 1)
    let ux = fx * fx * (3 - 2 * fx)
    let uy = fy * fy * (3 - 2 * fy)
    return (a * (1 - ux) + b * ux) * (1 - uy) + (c * (1 - ux) + d * ux) * uy
}
func fbm(_ x0: Double, _ y0: Double) -> Double {
    var v = 0.0, a = 0.5, x = x0, y = y0
    for _ in 0..<5 { v += a * vnoise(x, y); x *= 2.02; y *= 2.02; a *= 0.5 }
    return v
}

// ---- Blob field parameters (a flattering static pose) ----
let level = 0.55
let coreSize = 0.20
let reach = 0.58
let spikiness = 3.0
let viscosity = 0.038
let spikeCount = 9

struct Sat { let cx: Double; let cy: Double; let r: Double }
let satellites: [Sat] = (0..<spikeCount).map { i in
    let fi = Double(i)
    let seed = hash21(fi, 1.0)
    let ang = fi * 2.39996
    let rad = coreSize * 0.55 + (reach * level) * (0.4 + 0.6 * vnoise(fi, 0))
    let ri = (0.03 + 0.06 * level) * (0.55 + 0.9 * seed)
    return Sat(cx: rad * cos(ang), cy: rad * sin(ang), r: ri)
}

func metaball(_ px: Double, _ py: Double, _ cx: Double, _ cy: Double, _ r: Double) -> Double {
    let dx = px - cx, dy = py - cy
    return (r * r) / (dx * dx + dy * dy + 1e-4)
}

/// Ink coverage 0...1 at uv (centered, ~[-1,1]).
func ink(_ ux: Double, _ uy: Double) -> Double {
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
    // Radial cleanup: fade stray wisps near the squircle edge.
    k *= smoothstep(1.30, 0.95, sqrt(ux * ux + uy * uy))
    return k
}

// ---- Render master at 1024 per-pixel ----
let MASTER = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: MASTER, height: MASTER, bitsPerComponent: 8,
                    bytesPerRow: MASTER * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let ptr = ctx.data!.bindMemory(to: UInt8.self, capacity: MASTER * MASTER * 4)

let S = Double(MASTER)
let inset = S * 0.085
let half = (S - 2 * inset) / 2
let cornerR = (S - 2 * inset) * 0.2237
let cx0 = S / 2, cy0 = S / 2
let uvScale = 1.32  // maps the blob to a pleasing fraction of the squircle

for y in 0..<MASTER {
    for x in 0..<MASTER {
        let fx = Double(x) + 0.5, fy = Double(y) + 0.5

        // Rounded-rect signed distance for the squircle + AA coverage.
        let dx = abs(fx - cx0) - (half - cornerR)
        let dy = abs(fy - cy0) - (half - cornerR)
        let outside = sqrt(pow(max(dx, 0), 2) + pow(max(dy, 0), 2)) + min(max(dx, dy), 0) - cornerR
        let coverage = smoothstep(1.0, -1.0, outside)

        var r = 0.0, g = 0.0, b = 0.0, a = 0.0
        if coverage > 0 {
            // Background gradient (top white -> bottom light gray).
            let v = Double(y) / S
            let bg = 1.0 - 0.12 * v

            // Blob ink in uv space.
            let ux = (fx / S * 2 - 1) * uvScale
            let uy = (fy / S * 2 - 1) * uvScale
            let k = ink(ux, uy)

            let blob = 0.04
            var lum = bg * (1 - k) + blob * k
            // Wet sheen toward the upper area of the blob.
            let sheen = smoothstep(0.0, 0.8, -uy) * 0.10 * k
            lum += sheen

            r = lum; g = lum; b = lum
            a = coverage
        }

        let i = (y * MASTER + x) * 4
        ptr[i + 0] = UInt8(max(0, min(255, r * a * 255)))
        ptr[i + 1] = UInt8(max(0, min(255, g * a * 255)))
        ptr[i + 2] = UInt8(max(0, min(255, b * a * 255)))
        ptr[i + 3] = UInt8(max(0, min(255, a * 255)))
    }
}

let master = ctx.makeImage()!

// ---- Emit all required sizes by high-quality downscale ----
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for (name, px) in sizes {
    let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                      bytesPerRow: px * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    c.draw(master, in: CGRect(x: 0, y: 0, width: px, height: px))
    let img = c.makeImage()!
    let rep = NSBitmapImageRep(cgImage: img)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
    print("wrote \(name).png (\(px)px)")
}
print("iconset ready at \(outDir)")
