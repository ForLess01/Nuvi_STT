import Foundation

/// Sparse control/publisher-side diagnostics. Never call from an audio render
/// callback. Owners are ephemeral session IDs, not user or device information.
internal struct AudioPhaseTiming {
    private let phase: String
    private let owner: String
    private let started: UInt64

    init(_ phase: String, owner: String) {
        self.phase = phase
        self.owner = owner
        started = DispatchTime.now().uptimeNanoseconds
        NSLog("Nuvi/timing: phase=%@ owner=%@ started_ns=%llu", phase, owner, started)
    }

    func finish() {
        Self.record(phase, owner: owner, since: started)
    }

    static func record(_ phase: String, owner: String, since started: UInt64) {
        let ended = DispatchTime.now().uptimeNanoseconds
        let elapsed = Double(ended - started) / 1_000_000
        NSLog("Nuvi/timing: phase=%@ owner=%@ ended_ns=%llu elapsed_ms=%.3f",
              phase, owner, ended, elapsed)
    }

    static func measure<T>(_ phase: String, owner: String, _ operation: () throws -> T) rethrows -> T {
        let timing = Self(phase, owner: owner)
        defer { timing.finish() }
        return try operation()
    }
}
