import CoreAudio
import Testing
@testable import HoldToTalk

/// Pre-warming the capture engine opens the input device. On Bluetooth that
/// forces the headset out of A2DP into the hands-free profile, dropping playback
/// to call quality for as long as the app runs — a bad trade for 140ms.
@Suite("Audio Input Device Tests")
struct AudioInputDeviceTests {
    @Test("Bluetooth transports are recognised")
    func bluetoothTransportsRecognised() {
        #expect(AudioInputDevice.isBluetooth(transportType: kAudioDeviceTransportTypeBluetooth))
        #expect(AudioInputDevice.isBluetooth(transportType: kAudioDeviceTransportTypeBluetoothLE))
    }

    @Test("Wired and built-in transports are not treated as Bluetooth")
    func wiredTransportsAreNotBluetooth() {
        for transport in [
            kAudioDeviceTransportTypeBuiltIn,
            kAudioDeviceTransportTypeUSB,
            kAudioDeviceTransportTypeAggregate,
            kAudioDeviceTransportTypeVirtual,
            kAudioDeviceTransportTypeThunderbolt,
        ] {
            #expect(!AudioInputDevice.isBluetooth(transportType: transport))
        }
    }

    @Test("Unknown transports keep the latency optimisation")
    func unknownTransportsStillPrewarm() {
        // Backing off is only worth it for the case we know is harmful;
        // everything else should keep the near-instant start.
        #expect(!AudioInputDevice.isBluetooth(transportType: kAudioDeviceTransportTypeUnknown))
    }

    @Test("Querying the current default input does not crash or hang")
    func defaultInputQueryIsSafe() {
        // Runs on whatever hardware CI has, including none.
        if let id = AudioInputDevice.defaultInputID {
            _ = AudioInputDevice.transportType(of: id)
        }
        _ = AudioInputDevice.prewarmWouldDegradePlayback
    }
}
