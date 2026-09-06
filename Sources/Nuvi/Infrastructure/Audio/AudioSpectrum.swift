import Foundation

public struct AudioSpectrum: Sendable, Equatable {
    public var level: Float   // 0...1 overall RMS
    public var bass: Float    // 0...1 (20 - 250 Hz)
    public var mid: Float     // 0...1 (250 - 2500 Hz)
    public var treble: Float  // 0...1 (2500 - 8000 Hz)

    public static let zero = AudioSpectrum(level: 0, bass: 0, mid: 0, treble: 0)

    public init(level: Float, bass: Float, mid: Float, treble: Float) {
        self.level = level
        self.bass = bass
        self.mid = mid
        self.treble = treble
    }
}
