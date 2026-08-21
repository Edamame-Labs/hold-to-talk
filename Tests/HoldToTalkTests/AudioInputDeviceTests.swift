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
        _ = AudioInputDevice.prewarmWouldDegradePlayback()
        _ = AudioInputDevice.availableInputs()
    }

    // MARK: - Device selection
    //
    // The app mirrors the system's chosen input unless the user picks one.
    // Ranking devices by transport type — quietly preferring the built-in mic
    // because a headset is "worse" — surprises people who chose that headset,
    // and makes the app disagree with System Settings.

    private static let builtIn = AudioInputDeviceInfo(
        id: 1, uid: "builtin-uid", name: "MacBook Pro Microphone",
        transportType: kAudioDeviceTransportTypeBuiltIn
    )
    private static let headset = AudioInputDeviceInfo(
        id: 2, uid: "airpods-uid", name: "AirPods Max",
        transportType: kAudioDeviceTransportTypeBluetooth
    )

    @Test("A chosen device is used even when it is Bluetooth")
    func chosenBluetoothDeviceIsHonoured() {
        let resolved = AudioInputDevice.resolvedInput(
            preferredUID: Self.headset.uid,
            available: [Self.builtIn, Self.headset]
        )
        #expect(resolved == Self.headset)
    }

    @Test("A chosen device wins over a built-in alternative")
    func selectionIsNotOverriddenByTransport() {
        let resolved = AudioInputDevice.resolvedInput(
            preferredUID: Self.headset.uid,
            available: [Self.headset, Self.builtIn]
        )
        #expect(resolved?.isBuiltIn != true)
    }

    @Test("A disconnected choice is reported rather than silently swapped")
    func missingPreferredDeviceIsReported() {
        #expect(AudioInputDevice.preferredInputIsMissing(
            preferredUID: "gone-uid", available: [Self.builtIn]
        ))
        #expect(!AudioInputDevice.preferredInputIsMissing(
            preferredUID: Self.builtIn.uid, available: [Self.builtIn]
        ))
        // No preference means nothing can be missing.
        #expect(!AudioInputDevice.preferredInputIsMissing(preferredUID: "", available: []))
        #expect(!AudioInputDevice.preferredInputIsMissing(preferredUID: nil, available: []))
    }

    @Test("Device kinds are classified from transport, not name")
    func deviceKindsFromTransport() {
        #expect(Self.headset.isBluetooth)
        #expect(!Self.headset.isBuiltIn)
        #expect(Self.builtIn.isBuiltIn)
        #expect(!Self.builtIn.isBluetooth)
    }

    @Test("Bluetooth start is retried while the route settles")
    func bluetoothStartIsRetried() {
        // A Bluetooth route is not usable the instant the device appears, so a
        // single attempt reports a dead microphone that is merely still settling.
        #expect(AudioRecorder.bluetoothStartAttempts > 1)
        #expect(AudioRecorder.bluetoothStartRetryDelay > 0)
        // The whole retry budget has to stay imperceptible — start() runs on the
        // hotkey path.
        let worstCase = Double(AudioRecorder.bluetoothStartAttempts - 1)
            * AudioRecorder.bluetoothStartRetryDelay
        #expect(worstCase < 0.5)
    }
}
