import XCTest
@testable import Nuvi

final class AudioDuckingServiceTests: XCTestCase {
    private func waitUntil(
        timeout: TimeInterval = 1.0,
        _ predicate: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testSmoothstepMath() {
        XCTAssertEqual(AudioDuckingEasing.smoothstep.ease(0.0), 0.0, accuracy: 0.0001)
        XCTAssertEqual(AudioDuckingEasing.smoothstep.ease(1.0), 1.0, accuracy: 0.0001)
        XCTAssertEqual(AudioDuckingEasing.smoothstep.ease(0.5), 0.5, accuracy: 0.0001)
        XCTAssertEqual(AudioDuckingEasing.cosineEaseInOut.ease(0.0), 0.0, accuracy: 0.0001)
        XCTAssertEqual(AudioDuckingEasing.cosineEaseInOut.ease(1.0), 1.0, accuracy: 0.0001)
        XCTAssertEqual(AudioDuckingEasing.cosineEaseInOut.ease(0.5), 0.5, accuracy: 0.0001)

        // Clamping bounds
        XCTAssertEqual(AudioDuckingEasing.smoothstep.ease(-0.5), 0.0, accuracy: 0.0001)
        XCTAssertEqual(AudioDuckingEasing.smoothstep.ease(1.5), 1.0, accuracy: 0.0001)
    }

    func testSmoothRampingDownAndUp() async {
        let fakeController = FakeVolumeController(initialVolume: 0.8)
        let service = SystemAudioDuckingService(
            volumeController: fakeController,
            duckFactor: 0.20,
            duckDuration: 0.06,
            restoreDuration: 0.06,
            stepInterval: 0.005
        )

        XCTAssertEqual(service.state, .restored)
        service.duck()

        await waitUntil { service.state == .ducked }

        XCTAssertEqual(service.state, .ducked)
        // 0.8 * 0.2 = 0.16
        let duckedVolume = try? XCTUnwrap(fakeController.currentVolume)
        XCTAssertEqual(duckedVolume ?? 0, 0.16, accuracy: 0.01)

        // Should have multiple smooth intermediate steps
        let historyAfterDuck = fakeController.volumeHistory
        XCTAssertGreaterThanOrEqual(historyAfterDuck.count, 4)
        // Monotonically non-increasing during ducking
        for i in 1..<historyAfterDuck.count {
            XCTAssertLessThanOrEqual(historyAfterDuck[i], historyAfterDuck[i - 1] + 0.001)
        }

        // Now restore back up
        fakeController.resetHistory()
        service.restore()

        await waitUntil { service.state == .restored }

        XCTAssertEqual(service.state, .restored)
        let restoredVolume = try? XCTUnwrap(fakeController.currentVolume)
        XCTAssertEqual(restoredVolume ?? 0, 0.8, accuracy: 0.01)

        let historyAfterRestore = fakeController.volumeHistory
        XCTAssertGreaterThanOrEqual(historyAfterRestore.count, 4)
        // Monotonically non-decreasing during restore
        for i in 1..<historyAfterRestore.count {
            XCTAssertGreaterThanOrEqual(historyAfterRestore[i], historyAfterRestore[i - 1] - 0.001)
        }
    }

    func testPreemptionDuckingToRestoring() async {
        let fakeController = FakeVolumeController(initialVolume: 1.0)
        let service = SystemAudioDuckingService(
            volumeController: fakeController,
            duckFactor: 0.20,
            duckDuration: 0.10,
            restoreDuration: 0.10,
            stepInterval: 0.005
        )

        service.duck()
        // Wait until volume is somewhere intermediate (e.g. between 0.4 and 0.8)
        await waitUntil {
            guard let vol = fakeController.currentVolume else { return false }
            return vol < 0.85 && vol > 0.35
        }

        let intermediateVolume = fakeController.currentVolume ?? 0.5
        fakeController.resetHistory()

        // Call restore while still ducking down
        service.restore()

        // The first volume set after restore should be near the intermediate volume, not jumping to 0.2 or 1.0
        await waitUntil { !fakeController.history.isEmpty }
        if let firstAfterPreempt = fakeController.history.first {
            XCTAssertEqual(firstAfterPreempt, intermediateVolume, accuracy: 0.08)
        }

        await waitUntil { service.state == .restored }
        XCTAssertEqual(service.state, .restored)
        XCTAssertEqual(fakeController.currentVolume ?? 0, 1.0, accuracy: 0.01)
    }

    func testPreemptionRestoringToDucking() async {
        let fakeController = FakeVolumeController(initialVolume: 1.0)
        let service = SystemAudioDuckingService(
            volumeController: fakeController,
            duckFactor: 0.20,
            duckDuration: 0.08,
            restoreDuration: 0.08,
            stepInterval: 0.005
        )

        service.duck()
        await waitUntil { service.state == .ducked }
        XCTAssertEqual(fakeController.currentVolume ?? 0, 0.2, accuracy: 0.01)

        // Start restoring
        service.restore()
        // Wait until volume ramps back up midway (e.g. > 0.45)
        await waitUntil { (fakeController.currentVolume ?? 0) > 0.45 }
        let intermediate = fakeController.currentVolume ?? 0.5
        fakeController.resetHistory()

        // Preempt back to ducking
        service.duck()

        await waitUntil { !fakeController.history.isEmpty }
        if let firstAfterPreempt = fakeController.history.first {
            XCTAssertEqual(firstAfterPreempt, intermediate, accuracy: 0.08)
        }

        await waitUntil { service.state == .ducked }
        XCTAssertEqual(fakeController.currentVolume ?? 0, 0.2, accuracy: 0.01)

        // Finally restore all the way to original 1.0
        service.restore()
        await waitUntil { service.state == .restored }
        XCTAssertEqual(fakeController.currentVolume ?? 0, 1.0, accuracy: 0.01)
    }

    func testIdempotence() async {
        let fakeController = FakeVolumeController(initialVolume: 0.8)
        let service = SystemAudioDuckingService(
            volumeController: fakeController,
            duckFactor: 0.20,
            duckDuration: 0.04,
            restoreDuration: 0.04,
            stepInterval: 0.005
        )

        service.duck()
        service.duck() // Duplicate call while ducking

        await waitUntil { service.state == .ducked }
        XCTAssertEqual(fakeController.currentVolume ?? 0, 0.16, accuracy: 0.01)

        service.duck() // Duplicate call when already ducked
        XCTAssertEqual(service.state, .ducked)
        XCTAssertEqual(fakeController.currentVolume ?? 0, 0.16, accuracy: 0.01)

        service.restore()
        await waitUntil { service.state == .restored }
        XCTAssertEqual(fakeController.currentVolume ?? 0, 0.8, accuracy: 0.01)

        service.restore() // Duplicate call when already restored
        XCTAssertEqual(service.state, .restored)
        XCTAssertEqual(fakeController.currentVolume ?? 0, 0.8, accuracy: 0.01)
    }

    func testSafetyClampingAndEdgeCases() async {
        // Initial volume zero (muted)
        let mutedController = FakeVolumeController(initialVolume: 0.0)
        let mutedService = SystemAudioDuckingService(
            volumeController: mutedController,
            duckDuration: 0.02,
            restoreDuration: 0.02
        )
        mutedService.duck()
        XCTAssertEqual(mutedController.currentVolume, 0.0)
        mutedService.restore()
        XCTAssertEqual(mutedController.currentVolume, 0.0)

        // Initial volume exceeding 1.0
        let overController = FakeVolumeController(initialVolume: 1.5)
        let overService = SystemAudioDuckingService(
            volumeController: overController,
            duckDuration: 0.02,
            restoreDuration: 0.02,
            stepInterval: 0.005
        )
        overService.duck()
        await waitUntil { overService.state == .ducked }
        // 1.0 clamped * 0.2 = 0.2
        XCTAssertEqual(overController.currentVolume ?? 0, 0.2, accuracy: 0.01)
        overService.restore()
        await waitUntil { overService.state == .restored }
        XCTAssertEqual(overController.currentVolume ?? 0, 1.0, accuracy: 0.01)

        // Nil volume from controller
        let nilController = FakeVolumeController(initialVolume: nil)
        let nilService = SystemAudioDuckingService(
            volumeController: nilController,
            duckDuration: 0.02,
            restoreDuration: 0.02
        )
        nilService.duck()
        XCTAssertEqual(nilService.state, .restored)
        nilService.restore()
        XCTAssertEqual(nilService.state, .restored)
    }

    func testDeinitSafetyRestoresOriginalVolume() async {
        let fakeController = FakeVolumeController(initialVolume: 0.75)
        do {
            let service = SystemAudioDuckingService(
                volumeController: fakeController,
                duckFactor: 0.20,
                duckDuration: 0.04,
                restoreDuration: 0.04,
                stepInterval: 0.005
            )
            service.duck()
            await waitUntil { service.state == .ducked }
            XCTAssertEqual(fakeController.currentVolume ?? 0, 0.15, accuracy: 0.01)
            // `service` falls out of scope here and is deallocated while ducked
        }

        // Deinit must have synchronously restored the volume to 0.75
        XCTAssertEqual(fakeController.currentVolume ?? 0, 0.75, accuracy: 0.01)
    }
}

// MARK: - FakeVolumeController

final class FakeVolumeController: AudioVolumeControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var volume: Float?
    private(set) var volumeHistory: [Float] = []
    private(set) var setVolumeCallCount = 0

    var history: [Float] {
        lock.lock()
        defer { lock.unlock() }
        return volumeHistory
    }

    func resetHistory() {
        lock.lock()
        defer { lock.unlock() }
        volumeHistory.removeAll()
    }

    var currentVolume: Float? {
        lock.lock()
        defer { lock.unlock() }
        return volume
    }

    init(initialVolume: Float?) {
        self.volume = initialVolume
        if let initialVolume {
            volumeHistory.append(initialVolume)
        }
    }

    func getVolume() -> Float? {
        lock.lock()
        defer { lock.unlock() }
        return volume
    }

    @discardableResult
    func setVolume(_ newVolume: Float) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        setVolumeCallCount += 1
        volume = newVolume
        volumeHistory.append(newVolume)
        return true
    }
}
