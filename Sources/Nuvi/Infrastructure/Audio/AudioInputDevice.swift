import CoreAudio
import AVFoundation

/// Picks a specific CoreAudio input device for capture.
///
/// Why this exists: when the system default input is a Bluetooth headset (e.g.
/// AirPods, WH-1000XM4), opening its microphone forces the device from A2DP
/// (stereo, high quality) into HFP/SCO ("hands-free", 16 kHz mono). That tanks
/// the volume and quality of whatever music is playing and only restores once the
/// mic is released. Capturing from the BUILT-IN microphone instead leaves the
/// headset in A2DP, so playback is never degraded.
enum AudioInputDevice {
    struct OutputState: Equatable, Sendable {
        let deviceID: AudioDeviceID
        let volume: Float32?
        let muted: Bool?
    }

    /// A selectable capture device (anything with input channels).
    struct Device: Identifiable, Hashable, Sendable {
        let id: AudioDeviceID
        let uid: String
        let name: String
        let isBluetooth: Bool

        var settingsLabel: String {
            isBluetooth ? "\(name) (Bluetooth — low quality mic)" : name
        }
    }

    /// All devices that can capture audio, for the Settings picker.
    static func inputDevices() -> [Device] {
        allDevices().compactMap { device in
            guard hasInputChannels(device),
                  let uid = stringProperty(device, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(device, kAudioObjectPropertyName) else { return nil }
            return Device(id: device, uid: uid, name: name, isBluetooth: isBluetoothTransport(device))
        }
    }

    /// Resolve a saved device UID back to a live device ID, or nil if unplugged.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        inputDevices().first { $0.uid == uid }?.id
    }

    /// Whether a capture device is Bluetooth/BLE. Opening these microphones
    /// forces macOS into hands-free/HFP mode, which degrades headphone playback.
    static func isBluetoothInputDevice(_ device: AudioDeviceID) -> Bool {
        isBluetoothTransport(device)
    }

    /// The built-in microphone's device ID, or nil if none is present.
    static func builtInInputDeviceID() -> AudioDeviceID? {
        for device in allDevices() where transportType(of: device) == kAudioDeviceTransportTypeBuiltIn {
            if hasInputChannels(device) { return device }
        }
        return nil
    }

    /// The system's current default input device, or nil if none.
    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return (status == noErr && device != AudioDeviceID(kAudioObjectUnknown)) ? device : nil
    }

    /// The system's current default output device, read without changing it.
    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return (status == noErr && device != AudioDeviceID(kAudioObjectUnknown)) ? device : nil
    }

    /// Reads the current output controls without changing the default device,
    /// volume, or mute state. This is diagnostic-only evidence for the native
    /// ducking probe; ducking itself is owned by VoiceProcessingIO.
    static func currentOutputState() -> OutputState? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }

        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var volume: Float32 = 0
        var volumeSize = UInt32(MemoryLayout<Float32>.size)
        let volumeStatus = AudioObjectGetPropertyData(
            deviceID,
            &volumeAddress,
            0,
            nil,
            &volumeSize,
            &volume
        )

        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var mute: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        let muteStatus = AudioObjectGetPropertyData(
            deviceID,
            &muteAddress,
            0,
            nil,
            &muteSize,
            &mute
        )

        return OutputState(
            deviceID: deviceID,
            volume: volumeStatus == noErr && volumeSize >= UInt32(MemoryLayout<Float32>.size)
                ? volume
                : nil,
            muted: muteStatus == noErr && muteSize >= UInt32(MemoryLayout<UInt32>.size)
                ? mute != 0
                : nil
        )
    }

    /// Points an AVAudioEngine's input node at a specific device. Must be called
    /// before the engine starts and before the input format is read, because the
    /// format follows the selected device.
    @discardableResult
    static func setInputDevice(_ deviceID: AudioDeviceID, on engine: AVAudioEngine) -> Bool {
        guard let unit = engine.inputNode.audioUnit else { return false }
        var device = deviceID
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        return status == noErr
    }

    /// The device the engine's input node is currently bound to, for verifying a
    /// `setInputDevice` actually took (the engine can silently rebind the default).
    static func currentInputDeviceID(on engine: AVAudioEngine) -> AudioDeviceID? {
        guard let unit = engine.inputNode.audioUnit else { return nil }
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            &size
        )
        return status == noErr ? device : nil
    }

    // MARK: - CoreAudio plumbing

    private static func allDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr
        else { return [] }
        return devices
    }

    private static func transportType(of device: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return 0 }
        return transport
    }

    private static func isBluetoothTransport(_ device: AudioDeviceID) -> Bool {
        let transport = transportType(of: device)
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func stringProperty(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func hasInputChannels(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return false }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, buffer) == noErr else { return false }

        let bufferList = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        for audioBuffer in bufferList where audioBuffer.mNumberChannels > 0 { return true }
        return false
    }
}
