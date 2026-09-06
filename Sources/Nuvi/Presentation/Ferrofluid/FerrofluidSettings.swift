import Foundation
import Combine

/// Plain RGB color (0...1 per channel). Codable so it persists with the rest of
/// the look, and maps straight to the shader's fluid/background uniforms.
public struct RGBColor: Codable, Sendable, Equatable {
    public var r: Float
    public var g: Float
    public var b: Float

    public init(_ r: Float, _ g: Float, _ b: Float) {
        self.r = r
        self.g = g
        self.b = b
    }

    public static let nuviCharcoal = RGBColor(0.058_824, 0.066_667, 0.086_275)
    public static let nuviSoftWhite = RGBColor(0.956_863, 0.960_784, 0.968_627)
    public static let nuviLavender = RGBColor(0.721_569, 0.607_843, 1.0)

    var nearestNuviPaletteColor: RGBColor {
        [Self.nuviCharcoal, Self.nuviSoftWhite, Self.nuviLavender]
            .min { distance(to: $0) < distance(to: $1) } ?? Self.nuviCharcoal
    }

    private func distance(to other: RGBColor) -> Float {
        let dr = r - other.r, dg = g - other.g, db = b - other.b
        return dr * dr + dg * dg + db * db
    }
}

/// Tunable look of the ferrofluid. These map 1:1 to shader uniforms, so the
/// Settings controls adjust the render in real time.
public struct FerrofluidSettings: Codable, Sendable, Equatable {
    public var coreSize: Float    // resting blob radius
    public var reach: Float       // how far spikes extend with audio
    public var spikiness: Float   // spike sharpness (power curve)
    public var viscosity: Float   // edge softness (lower = crisper liquid)
    public var speed: Float       // animation speed
    public var spikeCount: Float  // number of angular fingers
    public var sensitivity: Float // audio responsiveness multiplier (0.2...3.0)
    public var fluidColor: RGBColor       // the liquid ink
    public var backgroundColor: RGBColor  // the chamber behind it

    // Decodes older persisted data (before colors existed) by defaulting the
    // color fields, so a saved look never fails to load.
    enum CodingKeys: String, CodingKey {
        case coreSize, reach, spikiness, viscosity, speed, spikeCount, sensitivity, fluidColor, backgroundColor
    }

    public init(coreSize: Float, reach: Float, spikiness: Float, viscosity: Float,
                speed: Float, spikeCount: Float, sensitivity: Float = 1.0,
                fluidColor: RGBColor = .nuviCharcoal,
                backgroundColor: RGBColor = .nuviSoftWhite) {
        self.coreSize = coreSize
        self.reach = reach
        self.spikiness = spikiness
        self.viscosity = viscosity
        self.speed = speed
        self.spikeCount = spikeCount
        self.sensitivity = sensitivity
        self.fluidColor = fluidColor
        self.backgroundColor = backgroundColor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        coreSize = try c.decode(Float.self, forKey: .coreSize)
        reach = try c.decode(Float.self, forKey: .reach)
        spikiness = try c.decode(Float.self, forKey: .spikiness)
        viscosity = try c.decode(Float.self, forKey: .viscosity)
        speed = try c.decode(Float.self, forKey: .speed)
        spikeCount = try c.decode(Float.self, forKey: .spikeCount)
        sensitivity = try c.decodeIfPresent(Float.self, forKey: .sensitivity) ?? 1.0
        fluidColor = (try c.decodeIfPresent(RGBColor.self, forKey: .fluidColor) ?? .nuviCharcoal)
            .nearestNuviPaletteColor
        backgroundColor = (try c.decodeIfPresent(RGBColor.self, forKey: .backgroundColor) ?? .nuviSoftWhite)
            .nearestNuviPaletteColor
    }

    public static let `default` = FerrofluidSettings(
        coreSize: 0.16,
        reach: 0.72,
        spikiness: 2.2,
        viscosity: 0.035,
        speed: 1.12,
        spikeCount: 8,
        sensitivity: 1.0,
        fluidColor: .nuviCharcoal,
        backgroundColor: .nuviSoftWhite
    )
}

/// A named, curated look the user can apply with one tap.
public struct FerrofluidPreset: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let settings: FerrofluidSettings
}

public extension FerrofluidSettings {
    /// Curated presets. Each sets both colors and shape so it reads as a
    /// finished look, not just a palette swap.
    static let presets: [FerrofluidPreset] = [
        FerrofluidPreset(name: "Classic", settings: .default),
        FerrofluidPreset(name: "Night", settings: FerrofluidSettings(
            coreSize: 0.18, reach: 0.62, spikiness: 1.8, viscosity: 0.028, speed: 0.95, spikeCount: 7,
            fluidColor: .nuviSoftWhite, backgroundColor: .nuviCharcoal)),
        FerrofluidPreset(name: "Lavender", settings: FerrofluidSettings(
            coreSize: 0.15, reach: 0.85, spikiness: 3.0, viscosity: 0.030, speed: 1.30, spikeCount: 9,
            fluidColor: .nuviLavender, backgroundColor: .nuviCharcoal)),
        FerrofluidPreset(name: "Ink", settings: FerrofluidSettings(
            coreSize: 0.17, reach: 0.78, spikiness: 2.6, viscosity: 0.040, speed: 1.05, spikeCount: 8,
            fluidColor: .nuviCharcoal, backgroundColor: .nuviLavender)),
        FerrofluidPreset(name: "Halo", settings: FerrofluidSettings(
            coreSize: 0.16, reach: 0.80, spikiness: 2.2, viscosity: 0.034, speed: 1.15, spikeCount: 8,
            fluidColor: .nuviLavender, backgroundColor: .nuviSoftWhite))
    ]
}

/// Observable, persisted store for the ferrofluid look. Shared so the pill and
/// the Settings preview render from the exact same values.
@MainActor
public final class FerrofluidSettingsStore: ObservableObject {
    public static let shared = FerrofluidSettingsStore()

    @Published public var settings: FerrofluidSettings {
        didSet { save() }
    }

    private let key = "nuvi.ferrofluid"
    private var pendingSave: DispatchWorkItem?

    public init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(FerrofluidSettings.self, from: data) {
            settings = decoded
        } else {
            settings = .default
        }
    }

    public func reset() {
        settings = .default
    }

    private func save() {
        pendingSave?.cancel()
        let settings = settings
        let key = key
        let work = DispatchWorkItem {
            if let data = try? JSONEncoder().encode(settings) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}
