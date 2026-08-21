import AppKit
import XCTest
@testable import HoldToTalk

final class RecordingHUDTests: XCTestCase {
    @MainActor
    func testHUDPanelDoesNotSwallowClicks() {
        // The overlay is informational. Without this it blocks clicks across a
        // 332x108 region at the bottom of every screen while recording.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 332, height: 108),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        XCTAssertFalse(panel.ignoresMouseEvents, "precondition: AppKit default is to receive clicks")

        configureHUDPanelForPassthrough(panel)

        XCTAssertTrue(panel.ignoresMouseEvents)
    }

    func testRestingOriginCentersHUDIndependentlyOnEachScreen() {
        let panelSize = CGSize(width: 300, height: 108)
        let primary = recordingHUDRestingOrigin(
            screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            visibleFrame: CGRect(x: 0, y: 40, width: 1728, height: 1052),
            panelSize: panelSize,
            shadowInset: 20
        )
        let secondary = recordingHUDRestingOrigin(
            screenFrame: CGRect(x: 1728, y: 120, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 1728, y: 120, width: 1920, height: 1055),
            panelSize: panelSize,
            shadowInset: 20
        )

        XCTAssertEqual(primary.x, 714)
        XCTAssertEqual(primary.y, 40)
        XCTAssertEqual(secondary.x, 2538)
        XCTAssertEqual(secondary.y, 120)
    }
}
