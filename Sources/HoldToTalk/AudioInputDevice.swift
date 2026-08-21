import CoreAudio
import Foundation

/// One selectable microphone.
struct AudioInputDeviceInfo: Identifiable, Equatable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transportType: UInt32

    var isBluetooth: Bool { AudioInputDevice.isBluetooth(transportType: transportType) }
    var isBuiltIn: Bool { transportType == kAudioDeviceTransportTypeBuiltIn }
}

/// Microphone enumeration and selection.
///
/// The app mirrors the system's chosen input unless the user picks a specific
/// device here. It deliberately never ranks devices by transport type — quietly
/// preferring the built-in mic because a headset is "worse" surprises people who
/// chose that headset on purpose, and it makes the app disagree with the input
/// shown in System Settings.
///
/// Bluetooth is where that choice costs something. A headset cannot be a
/// microphone and a high-quality speaker at the same time: offering it as an
/// input forces it out of A2DP into the hands-free profile, and everything the
/// user hears drops to call quality (measurably, 48 kHz to 24 kHz on AirPods
/// Max) for as long as the input stays open. So the app surfaces that cost and
/// declines to pre-warm such a device, rather than silently switching away from
/// the microphone the user selected.
enum AudioInputDevice {
    // MARK: - Transport

    static func isBluetooth(transportType: UInt32) -> Bool {
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    // MARK: - Enumeration

    static func availableInputs() -> [AudioInputDeviceInfo] {
        allDeviceIDs().compactMap { info(for: $0) }
    }

    static var defaultInputID: AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    static func defaultInput() -> AudioInputDeviceInfo? {
        guard let id = defaultInputID else { return nil }
        return info(for: id)
    }

    /// The device capture should actually use.
    ///
    /// A stored preference wins while that device is present; otherwise this
    /// falls back to the system default, so unplugging a chosen mic degrades to
    /// "whatever macOS is using" instead of failing.
    static func resolvedInput(
        preferredUID: String?,
        available: [AudioInputDeviceInfo]? = nil
    ) -> AudioInputDeviceInfo? {
        let devices = available ?? availableInputs()
        if let preferredUID, !preferredUID.isEmpty,
           let match = devices.first(where: { $0.uid == preferredUID }) {
            return match
        }
        return defaultInput()
    }

    /// Whether a stored preference names a device that is not currently present.
    static func preferredInputIsMissing(
        preferredUID: String?,
        available: [AudioInputDeviceInfo]? = nil
    ) -> Bool {
        guard let preferredUID, !preferredUID.isEmpty else { return false }
        let devices = available ?? availableInputs()
        return !devices.contains { $0.uid == preferredUID }
    }

    // MARK: - Pre-warm policy

    /// Whether holding the input device open would degrade playback.
    ///
    /// Unknown devices keep the latency optimisation: Bluetooth is the specific
    /// case worth backing off from, not everything unfamiliar.
    static func prewarmWouldDegradePlayback(preferredUID: String? = nil) -> Bool {
        resolvedInput(preferredUID: preferredUID)?.isBluetooth ?? false
    }

    // MARK: - Properties

    static func transportType(of deviceID: AudioDeviceID) -> UInt32? {
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport)
        guard status == noErr else { return nil }
        return transport
    }

    private static func info(for deviceID: AudioDeviceID) -> AudioInputDeviceInfo? {
        guard hasInputChannels(deviceID),
              let uid = stringProperty(deviceID, kAudioDevicePropertyDeviceUID),
              let name = stringProperty(deviceID, kAudioObjectPropertyName) else {
            return nil
        }
        return AudioInputDeviceInfo(
            id: deviceID,
            uid: uid,
            name: name,
            transportType: transportType(of: deviceID) ?? kAudioDeviceTransportTypeUnknown
        )
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var size: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    private static func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var size: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0 else { return false }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, buffer) == noErr else {
            return false
        }

        let list = UnsafeMutableAudioBufferListPointer(
            buffer.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func stringProperty(
        _ deviceID: AudioDeviceID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        let string = value as String
        return string.isEmpty ? nil : string
    }

    // MARK: - Change notifications

    /// Calls `handler` whenever the default input or the device list changes, so
    /// a headset connected while the app is idle is noticed rather than waited
    /// out until the next dictation.
    static func observeDefaultInputChanges(
        _ handler: @escaping @Sendable () -> Void
    ) -> AudioInputObservation {
        AudioInputObservation(handler: handler)
    }
}

/// Live registration for input-route changes. Deregisters on deinit.
final class AudioInputObservation: @unchecked Sendable {
    private static let selectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioHardwarePropertyDevices,
    ]

    private let block: AudioObjectPropertyListenerBlock

    init(handler: @escaping @Sendable () -> Void) {
        block = { _, _ in handler() }
        for selector in Self.selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
            )
        }
    }

    deinit {
        for selector in Self.selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
            )
        }
    }
}
