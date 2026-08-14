#!/usr/bin/env swift
// Generates the macOS app icon from Nuvi's official isologo-only SVG asset.
import AppKit
import CoreGraphics
import Foundation

let scriptURL = URL(fileURLWithPath: #filePath)
let root = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let outputDirectory = root.appendingPathComponent("build/Nuvi.iconset")
let isologoURL = root.appendingPathComponent(
    "Sources/Nuvi/Presentation/Brand/Assets/NuviIsologoDark.svg"
)

try? FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)

guard let isologo = NSImage(contentsOf: isologoURL) else {
    fatalError("Could not load official Nuvi isologo at \(isologoURL.path)")
}

let masterSize = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(
    data: nil,
    width: masterSize,
    height: masterSize,
    bitsPerComponent: 8,
    bytesPerRow: masterSize * 4,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

let canvas = CGRect(x: 0, y: 0, width: masterSize, height: masterSize)
let tile = canvas.insetBy(dx: 58, dy: 58)
let tilePath = CGPath(
    roundedRect: tile,
    cornerWidth: tile.width * 0.225,
    cornerHeight: tile.height * 0.225,
    transform: nil
)

// Palette: Charcoal #0F1116, Soft White #F4F5F7, Lavender #B89BFF.
context.addPath(tilePath)
context.setFillColor(CGColor(srgbRed: 15 / 255, green: 17 / 255, blue: 22 / 255, alpha: 1))
context.fillPath()

context.saveGState()
context.addPath(tilePath)
context.clip()
let glowColors = [
    CGColor(srgbRed: 184 / 255, green: 155 / 255, blue: 255 / 255, alpha: 0.17),
    CGColor(srgbRed: 15 / 255, green: 17 / 255, blue: 22 / 255, alpha: 0)
] as CFArray
let glow = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0, 1])!
context.drawRadialGradient(
    glow,
    startCenter: CGPoint(x: 512, y: 610),
    startRadius: 0,
    endCenter: CGPoint(x: 512, y: 610),
    endRadius: 520,
    options: []
)
context.restoreGState()

context.addPath(tilePath)
context.setStrokeColor(CGColor(srgbRed: 184 / 255, green: 155 / 255, blue: 255 / 255, alpha: 0.30))
context.setLineWidth(5)
context.strokePath()

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
let markRect = CGRect(x: 222, y: 220, width: 580, height: 580)
isologo.draw(in: markRect, from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()

let master = context.makeImage()!
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for (name, pixels) in sizes {
    let destination = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: pixels * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    destination.interpolationQuality = .high
    destination.draw(master, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    let representation = NSBitmapImageRep(cgImage: destination.makeImage()!)
    let data = representation.representation(using: .png, properties: [:])!
    try data.write(to: outputDirectory.appendingPathComponent("\(name).png"))
    print("wrote \(name).png (\(pixels)px)")
}

print("iconset ready at \(outputDirectory.path)")
