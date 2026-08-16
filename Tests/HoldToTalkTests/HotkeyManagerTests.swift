import XCTest
@testable import HoldToTalk

final class HotkeyManagerTests: XCTestCase {
    func testSelectableKindsIncludesEveryKind() {
        XCTAssertEqual(HotkeyManager.Hotkey.selectableKinds, HotkeyManager.Hotkey.Kind.allCases)
    }

    func testSelectionRoundTripsKindAndSide() {
        for kind in HotkeyManager.Hotkey.Kind.allCases {
            let sides: [HotkeyManager.Hotkey.ModifierSide] = kind.supportsSideSelection
                ? HotkeyManager.Hotkey.ModifierSide.allCases
                : [.either]

            for side in sides {
                let hotkey = HotkeyManager.Hotkey.selection(kind: kind, side: side)
                XCTAssertEqual(hotkey.kind, kind)
                XCTAssertEqual(hotkey.modifierSide, side)
            }
        }
    }

    func testDisplayNamesPreserveModifierSide() {
        XCTAssertEqual(HotkeyManager.Hotkey.control.displayName, "Control")
        XCTAssertEqual(HotkeyManager.Hotkey.leftControl.displayName, "Left Control")
        XCTAssertEqual(HotkeyManager.Hotkey.rightOption.displayName, "Right Option")
        XCTAssertEqual(HotkeyManager.Hotkey.commandShiftSpace.displayName, "Command+Shift+Space")
    }

    func testModifierOnlyHotkeysShowGenericConflictWarning() {
        for hotkey in [
            HotkeyManager.Hotkey.fn,
            .control,
            .leftOption,
            .rightCommand,
            .shift,
        ] {
            XCTAssertNotNil(hotkey.conflictWarning)
        }
    }

    func testConflictWarningExplainsGenericResolution() {
        let warning = HotkeyManager.Hotkey.fn.conflictWarning

        XCTAssertTrue(warning?.contains("macOS or other apps") == true)
        XCTAssertTrue(warning?.contains("choose a key combination") == true)
    }

    func testRegisteredHotkeysDoNotShowModifierConflictWarning() {
        for hotkey in [
            HotkeyManager.Hotkey.f13,
            .f19,
            .optionSpace,
            .controlSpace,
            .commandShiftSpace,
        ] {
            XCTAssertNil(hotkey.conflictWarning)
        }
    }
}
