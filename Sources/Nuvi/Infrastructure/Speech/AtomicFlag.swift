import os

/// Minimal thread-safe latch: starts false, flips to true once and stays. Written
/// from the audio thread, read from the transcription task — hence the lock.
final class AtomicFlag: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    var value: Bool { state.withLock { $0 } }

    func set() { state.withLock { $0 = true } }
}
