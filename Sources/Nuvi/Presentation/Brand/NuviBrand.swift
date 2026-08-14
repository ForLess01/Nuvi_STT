import AppKit
import SwiftUI

/// The only chromatic values in Nuvi's visual identity. Opacity variants are
/// derived from these colors rather than introducing additional hues.
enum NuviPalette {
    static let softWhiteHex = "#F4F5F7"
    static let charcoalHex = "#0F1116"
    static let lavenderHex = "#B89BFF"

    static let softWhite = Color(red: 244 / 255, green: 245 / 255, blue: 247 / 255)
    static let charcoal = Color(red: 15 / 255, green: 17 / 255, blue: 22 / 255)
    static let lavender = Color(red: 184 / 255, green: 155 / 255, blue: 255 / 255)

    static let nsSoftWhite = NSColor(srgbRed: 244 / 255, green: 245 / 255, blue: 247 / 255, alpha: 1)
    static let nsCharcoal = NSColor(srgbRed: 15 / 255, green: 17 / 255, blue: 22 / 255, alpha: 1)
    static let nsLavender = NSColor(srgbRed: 184 / 255, green: 155 / 255, blue: 255 / 255, alpha: 1)

    static let fluidCharcoal = RGBColor(15 / 255, 17 / 255, 22 / 255)
    static let fluidSoftWhite = RGBColor(244 / 255, 245 / 255, 247 / 255)
    static let fluidLavender = RGBColor(184 / 255, 155 / 255, 255 / 255)
}

enum NuviBrand {
    /// Appearance-aware official isologo. The lavender dot remains branded,
    /// while the main mark swaps between approved palette values for contrast.
    static func menuBarImage(pointSize: CGFloat = 20) -> NSImage {
        guard let dark = resourceImage(named: "NuviIsologoDark"),
              let light = resourceImage(named: "NuviIsologoLight") else {
            return FerrofluidBlobImage.menuBarSpectrumImage(pointSize: pointSize)
        }

        let size = NSSize(width: pointSize, height: pointSize)
        let image = NSImage(size: size, flipped: false) { rect in
            let match = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua])
            let source = match == .darkAqua ? dark : light
            source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Nuvi"
        return image
    }

    static func wordmarkImage() -> NSImage? {
        resourceImage(named: "NuviWordmarkDark")
    }

    private static func resourceImage(named name: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "svg") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}
