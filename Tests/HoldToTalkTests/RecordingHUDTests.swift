import AppKit
import XCTest
@testable import HoldToTalk

final class RecordingHUDTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    private let visible = CGRect(x: 0, y: 40, width: 1728, height: 1052)
    private let panel = CGSize(width: 224, height: 84)   // 184x44 plus shadow inset
    private let inset: CGFloat = 20

    private func origin(_ position: RecordingHUDPosition, cursor: CGPoint? = nil) -> CGPoint {
        recordingHUDOrigin(
            position: position,
            screenFrame: screen,
            visibleFrame: visible,
            panelSize: panel,
            shadowInset: inset,
            cursorPoint: cursor
        )
    }

    // MARK: - Placement

    func testTopAndBottomHugTheirOwnEdges() {
        let bottom = origin(.bottom)
        let top = origin(.top)

        // Both horizontally centred, but at opposite ends of the visible frame.
        XCTAssertEqual(bottom.x, top.x)
        XCTAssertEqual(bottom.y, visible.minY + 20 - inset)
        XCTAssertEqual(top.y, visible.maxY - panel.height - 20 + inset)
        XCTAssertGreaterThan(top.y, bottom.y)
    }

    func testCursorPlacementSitsClearOfThePointer() {
        let cursor = CGPoint(x: 800, y: 600)
        let placed = origin(.cursor, cursor: cursor)

        // Horizontally centred on the pointer, and entirely below it.
        XCTAssertEqual(placed.x + panel.width / 2, cursor.x)
        XCTAssertLessThan(placed.y + panel.height - inset, cursor.y)
    }

    func testCursorPlacementStaysOnScreenInEveryCorner() {
        let corners = [
            CGPoint(x: visible.minX, y: visible.minY),
            CGPoint(x: visible.maxX, y: visible.minY),
            CGPoint(x: visible.minX, y: visible.maxY),
            CGPoint(x: visible.maxX, y: visible.maxY),
        ]

        for corner in corners {
            let placed = origin(.cursor, cursor: corner)
            // The shadow inset is transparent, so the capsule itself must land
            // inside the visible frame even though the panel overhangs it.
            XCTAssertGreaterThanOrEqual(placed.x + inset, visible.minX, "corner \(corner)")
            XCTAssertLessThanOrEqual(placed.x + panel.width - inset, visible.maxX, "corner \(corner)")
            XCTAssertGreaterThanOrEqual(placed.y + inset, visible.minY, "corner \(corner)")
            XCTAssertLessThanOrEqual(placed.y + panel.height - inset, visible.maxY, "corner \(corner)")
        }
    }

    func testCursorPlacementFallsBackToBottomWithoutAPointer() {
        XCTAssertEqual(origin(.cursor, cursor: nil), origin(.bottom))
    }

    func testPositionRawValuesAreStableAcrossReleases() {
        // Persisted in UserDefaults; renaming silently resets the user's choice.
        XCTAssertEqual(RecordingHUDPosition.bottom.rawValue, "bottom")
        XCTAssertEqual(RecordingHUDPosition.top.rawValue, "top")
        XCTAssertEqual(RecordingHUDPosition.cursor.rawValue, "cursor")
    }


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
