import Foundation
import Combine

/// Tunable look of the ferrofluid. These map 1:1 to shader uniforms, so the
/// Settings sliders adjust the render in real time.
public struct FerrofluidSettings: Codable, Sendable, Equatable {
    public var coreSize: Float    // resting blob radius
    public var reach: Float       // how far spikes extend with audio
    public var spikiness: Float   // spike sharpness (power curve)
    public var viscosity: Float   // edge softness (lower = crisper liquid)
    public var speed: Float       // animation speed
    public var spikeCount: Float  // number of angular fingers

    public static let `default` = FerrofluidSettings(
        coreSize: 0.16,
        reach: 0.72,
        spikiness: 2.2,
        viscosity: 0.035,
        speed: 1.12,
        spikeCount: 8
    )
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
