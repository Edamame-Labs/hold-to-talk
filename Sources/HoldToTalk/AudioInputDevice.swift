import CoreAudio
import Foundation

/// Facts about the current default audio input, used to decide whether keeping
/// the capture engine on hot standby is free or expensive.
///
/// It is free for built-in and wired inputs. It is not free for Bluetooth: macOS
/// can only offer a Bluetooth headset as an input by switching it out of A2DP
/// into the hands-free profile, which drops playback to call quality — mono and
/// noticeably quieter — for as long as the input stays open.
enum AudioInputDevice {
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

    static func isBluetooth(transportType: UInt32) -> Bool {
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    /// Whether holding the input device open would degrade playback.
    ///
    /// Unknown devices are treated as safe to pre-warm: the latency win is the
    /// default, and Bluetooth is the case we specifically back off from.
    static var prewarmWouldDegradePlayback: Bool {
        guard let deviceID = defaultInputID,
              let transport = transportType(of: deviceID) else {
            return false
        }
        return isBluetooth(transportType: transport)
    }

    /// Calls `handler` whenever the default input device changes, so a headset
    /// connected while the app is idle is noticed rather than waited out.
    static func observeDefaultInputChanges(
        _ handler: @escaping @Sendable () -> Void
    ) -> AudioInputObservation {
        AudioInputObservation(handler: handler)
    }
}

/// Live registration for default-input-device changes. Deregisters on deinit.
final class AudioInputObservation: @unchecked Sendable {
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private let block: AudioObjectPropertyListenerBlock

    init(handler: @escaping @Sendable () -> Void) {
        block = { _, _ in handler() }
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }
}
