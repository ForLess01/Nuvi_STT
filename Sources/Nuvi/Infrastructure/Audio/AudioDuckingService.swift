import Foundation
import CoreAudio
import AudioToolbox

// MARK: - AudioVolumeControlling

public protocol AudioVolumeControlling: Sendable {
    func getVolume() -> Float?
    @discardableResult
    func setVolume(_ volume: Float) -> Bool
}

// MARK: - CoreAudioVolumeController

public final class CoreAudioVolumeController: AudioVolumeControlling, @unchecked Sendable {
    public init() {}

    private func defaultOutputDeviceID() -> AudioObjectID? {
        var defaultOutputDeviceID = AudioObjectID(kAudioObjectUnknown)
        var propertySize = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &defaultOutputDeviceID
        )
        guard status == noErr, defaultOutputDeviceID != AudioObjectID(kAudioObjectUnknown) else {
            return nil
        }
        return defaultOutputDeviceID
    }

    public func getVolume() -> Float? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }

        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &volume
        )
        guard status == noErr else { return nil }
        return Float(volume)
    }

    @discardableResult
    public func setVolume(_ volume: Float) -> Bool {
        guard let deviceID = defaultOutputDeviceID() else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }

        let clamped = min(max(volume, 0.0), 1.0)
        var vol = Float32(clamped)
        let size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            size,
            &vol
        )
        return status == noErr
    }
}

// MARK: - AudioDucking

public protocol AudioDucking: Sendable {
    func duck()
    func restore()
}

// MARK: - AudioDuckingEasing

public enum AudioDuckingEasing: Sendable {
    case smoothstep
    case cosineEaseInOut

    public func ease(_ t: Double) -> Double {
        let clamped = min(max(t, 0.0), 1.0)
        switch self {
        case .smoothstep:
            return clamped * clamped * (3.0 - 2.0 * clamped)
        case .cosineEaseInOut:
            return (1.0 - cos(.pi * clamped)) / 2.0
        }
    }
}

// MARK: - SystemAudioDuckingService

public final class SystemAudioDuckingService: AudioDucking, @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case restored
        case ducking
        case ducked
        case restoring
    }

    private let lock = NSLock()
    private let volumeController: AudioVolumeControlling
    private let duckFactor: Float
    private let duckDuration: TimeInterval
    private let restoreDuration: TimeInterval
    private let stepInterval: TimeInterval
    private let easing: AudioDuckingEasing
    private let queue: DispatchQueue

    private var rampTimer: DispatchSourceTimer?
    private var originalVolume: Float?
    private var lastSetVolume: Float?
    private var targetVolume: Float?
    private var currentState: State = .restored

    public var state: State {
        lock.lock()
        defer { lock.unlock() }
        return currentState
    }

    public var isDucked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentState == .ducked || currentState == .ducking
    }

    public init(
        volumeController: AudioVolumeControlling = CoreAudioVolumeController(),
        duckFactor: Float = 0.20,
        duckDuration: TimeInterval = 0.15,
        restoreDuration: TimeInterval = 0.19,
        stepInterval: TimeInterval = 0.015,
        easing: AudioDuckingEasing = .smoothstep,
        queue: DispatchQueue = DispatchQueue(label: "nuvi.audio-ducking", qos: .userInteractive)
    ) {
        self.volumeController = volumeController
        self.duckFactor = duckFactor
        self.duckDuration = duckDuration
        self.restoreDuration = restoreDuration
        self.stepInterval = stepInterval
        self.easing = easing
        self.queue = queue
    }

    deinit {
        lock.lock()
        stopTimer()
        if let original = originalVolume, currentState != .restored {
            volumeController.setVolume(original)
        }
        lock.unlock()
    }

    public func duck() {
        lock.lock()
        defer { lock.unlock() }

        switch currentState {
        case .ducked, .ducking:
            // Idempotent: already ducked or currently ramping down
            return

        case .restored:
            guard let current = volumeController.getVolume() else {
                return
            }
            let clampedCurrent = min(max(current, 0.0), 1.0)
            originalVolume = clampedCurrent
            lastSetVolume = clampedCurrent

            let target = min(max(clampedCurrent * duckFactor, 0.0), 1.0)
            targetVolume = target

            if abs(clampedCurrent - target) < 0.001 {
                currentState = .ducked
                return
            }

            startRamp(from: clampedCurrent, to: target, duration: duckDuration, targetState: .ducked)

        case .restoring:
            // Preemption: reversing back down towards ducked volume
            guard let original = originalVolume else {
                currentState = .restored
                return
            }
            let target = min(max(original * duckFactor, 0.0), 1.0)
            targetVolume = target

            let current = volumeController.getVolume() ?? lastSetVolume ?? target
            let clampedCurrent = min(max(current, 0.0), 1.0)

            stopTimer()

            if abs(clampedCurrent - target) < 0.001 {
                applyVolume(target)
                currentState = .ducked
                return
            }

            let fullDistance = max(0.001, abs(original - target))
            let remainingDistance = abs(clampedCurrent - target)
            let proportionalDuration = max(0.02, duckDuration * Double(remainingDistance / fullDistance))

            startRamp(from: clampedCurrent, to: target, duration: proportionalDuration, targetState: .ducked)
        }
    }

    public func restore() {
        lock.lock()
        defer { lock.unlock() }

        switch currentState {
        case .restored, .restoring:
            // Idempotent: already restored or currently ramping up
            return

        case .ducked:
            guard let original = originalVolume else {
                currentState = .restored
                return
            }
            targetVolume = original
            let current = volumeController.getVolume() ?? lastSetVolume ?? (original * duckFactor)
            let clampedCurrent = min(max(current, 0.0), 1.0)

            if abs(clampedCurrent - original) < 0.001 {
                applyVolume(original)
                currentState = .restored
                originalVolume = nil
                targetVolume = nil
                return
            }

            startRamp(from: clampedCurrent, to: original, duration: restoreDuration, targetState: .restored)

        case .ducking:
            // Preemption: reversing back up towards original volume
            guard let original = originalVolume else {
                currentState = .restored
                return
            }
            let duckTarget = targetVolume ?? (original * duckFactor)
            let current = volumeController.getVolume() ?? lastSetVolume ?? duckTarget
            let clampedCurrent = min(max(current, 0.0), 1.0)

            stopTimer()

            if abs(clampedCurrent - original) < 0.001 {
                applyVolume(original)
                currentState = .restored
                originalVolume = nil
                targetVolume = nil
                return
            }

            let fullDistance = max(0.001, abs(original - duckTarget))
            let remainingDistance = abs(original - clampedCurrent)
            let proportionalDuration = max(0.02, restoreDuration * Double(remainingDistance / fullDistance))

            targetVolume = original
            startRamp(from: clampedCurrent, to: original, duration: proportionalDuration, targetState: .restored)
        }
    }

    private func applyVolume(_ volume: Float) {
        let clamped = min(max(volume, 0.0), 1.0)
        lastSetVolume = clamped
        volumeController.setVolume(clamped)
    }

    private func stopTimer() {
        if let timer = rampTimer {
            timer.setEventHandler(handler: nil)
            timer.cancel()
            rampTimer = nil
        }
    }

    private func startRamp(from startVolume: Float, to target: Float, duration: TimeInterval, targetState: State) {
        currentState = (targetState == .ducked) ? .ducking : .restoring
        targetVolume = target

        if duration <= 0.001 {
            applyVolume(target)
            currentState = targetState
            if targetState == .restored {
                originalVolume = nil
                targetVolume = nil
            }
            return
        }

        let startTime = ProcessInfo.processInfo.systemUptime
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        let intervalMs = max(1, Int(stepInterval * 1000))
        timer.schedule(
            deadline: .now(),
            repeating: .milliseconds(intervalMs),
            leeway: .milliseconds(2)
        )

        let easingFunction = easing
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }

            guard self.rampTimer === timer else { return }

            let elapsed = ProcessInfo.processInfo.systemUptime - startTime
            let progress = min(max(elapsed / duration, 0.0), 1.0)
            let easedProgress = Float(easingFunction.ease(progress))
            let nextVolume = startVolume + (target - startVolume) * easedProgress

            self.applyVolume(nextVolume)

            if progress >= 1.0 {
                self.stopTimer()
                self.applyVolume(target)
                self.currentState = targetState
                if targetState == .restored {
                    self.originalVolume = nil
                    self.targetVolume = nil
                }
            }
        }

        rampTimer = timer
        timer.resume()
    }
}
