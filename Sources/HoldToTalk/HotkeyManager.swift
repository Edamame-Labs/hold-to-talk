import AppKit
import Carbon
import Foundation

/// Handles global hold-to-talk shortcuts.
///
/// Regular keys and key combinations are registered with Carbon hotkeys. Bare
/// modifiers use AppKit flags-changed monitoring so we can test whether the
/// existing Accessibility permission is enough before adding any Input
/// Monitoring-specific flow.
final class HotkeyManager {
    enum Hotkey: String, CaseIterable {
        case fn
        case control
        case leftControl = "left_control"
        case rightControl = "right_control"
        case option
        case leftOption = "left_option"
        case rightOption = "right_option"
        case command
        case leftCommand = "left_command"
        case rightCommand = "right_command"
        case shift
        case leftShift = "left_shift"
        case rightShift = "right_shift"
        case f13
        case f14
        case f15
        case f16
        case f17
        case f18
        case f19
        case optionSpace = "option_space"
        case controlSpace = "control_space"
        case commandShiftSpace = "command_shift_space"

        var displayName: String {
            switch self {
            case .fn: return "Fn"
            case .control: return "Control"
            case .leftControl: return "Left Control"
            case .rightControl: return "Right Control"
            case .option: return "Option"
            case .leftOption: return "Left Option"
            case .rightOption: return "Right Option"
            case .command: return "Command"
            case .leftCommand: return "Left Command"
            case .rightCommand: return "Right Command"
            case .shift: return "Shift"
            case .leftShift: return "Left Shift"
            case .rightShift: return "Right Shift"
            case .f13: return "F13"
            case .f14: return "F14"
            case .f15: return "F15"
            case .f16: return "F16"
            case .f17: return "F17"
            case .f18: return "F18"
            case .f19: return "F19"
            case .optionSpace: return "Option+Space"
            case .controlSpace: return "Control+Space"
            case .commandShiftSpace: return "Command+Shift+Space"
            }
        }

        enum Kind: String, CaseIterable, Identifiable {
            case fn
            case control
            case option
            case command
            case shift
            case f13
            case f14
            case f15
            case f16
            case f17
            case f18
            case f19
            case optionSpace
            case controlSpace
            case commandShiftSpace

            var id: String { rawValue }

            var displayName: String {
                switch self {
                case .fn: return "Fn"
                case .control: return "Control"
                case .option: return "Option"
                case .command: return "Command"
                case .shift: return "Shift"
                case .f13: return "F13"
                case .f14: return "F14"
                case .f15: return "F15"
                case .f16: return "F16"
                case .f17: return "F17"
                case .f18: return "F18"
                case .f19: return "F19"
                case .optionSpace: return "Option+Space"
                case .controlSpace: return "Control+Space"
                case .commandShiftSpace: return "Command+Shift+Space"
                }
            }

            var supportsSideSelection: Bool {
                switch self {
                case .control, .option, .command, .shift:
                    return true
                case .fn, .f13, .f14, .f15, .f16, .f17, .f18, .f19,
                     .optionSpace, .controlSpace, .commandShiftSpace:
                    return false
                }
            }
        }

        enum ModifierSide: String, CaseIterable, Identifiable {
            case either
            case left
            case right

            var id: String { rawValue }

            var displayName: String {
                switch self {
                case .either: return "Either"
                case .left: return "Left"
                case .right: return "Right"
                }
            }
        }

        static func preferredSelection(from rawValue: String) -> Hotkey {
            if let hotkey = Hotkey(rawValue: rawValue) {
                return hotkey
            }

            switch rawValue {
            case "ctrl":
                return .control
            case "left_ctrl":
                return .leftControl
            case "right_ctrl":
                return .rightControl
            case "cmd":
                return .command
            case "left_cmd":
                return .leftCommand
            case "right_cmd":
                return .rightCommand
            default:
                return .fn
            }
        }

        static var selectableKinds: [Kind] {
            [
                .fn, .control, .option, .command, .shift,
                .f13, .f14, .f15, .f16, .f17, .f18, .f19,
                .optionSpace, .controlSpace, .commandShiftSpace,
            ]
        }

        static func selection(kind: Kind, side: ModifierSide = .either) -> Hotkey {
            switch kind {
            case .fn:
                return .fn
            case .control:
                switch side {
                case .either: return .control
                case .left: return .leftControl
                case .right: return .rightControl
                }
            case .option:
                switch side {
                case .either: return .option
                case .left: return .leftOption
                case .right: return .rightOption
                }
            case .command:
                switch side {
                case .either: return .command
                case .left: return .leftCommand
                case .right: return .rightCommand
                }
            case .shift:
                switch side {
                case .either: return .shift
                case .left: return .leftShift
                case .right: return .rightShift
                }
            case .f13:
                return .f13
            case .f14:
                return .f14
            case .f15:
                return .f15
            case .f16:
                return .f16
            case .f17:
                return .f17
            case .f18:
                return .f18
            case .f19:
                return .f19
            case .optionSpace:
                return .optionSpace
            case .controlSpace:
                return .controlSpace
            case .commandShiftSpace:
                return .commandShiftSpace
            }
        }

        var kind: Kind {
            switch self {
            case .fn:
                return .fn
            case .control, .leftControl, .rightControl:
                return .control
            case .option, .leftOption, .rightOption:
                return .option
            case .command, .leftCommand, .rightCommand:
                return .command
            case .shift, .leftShift, .rightShift:
                return .shift
            case .f13:
                return .f13
            case .f14:
                return .f14
            case .f15:
                return .f15
            case .f16:
                return .f16
            case .f17:
                return .f17
            case .f18:
                return .f18
            case .f19:
                return .f19
            case .optionSpace:
                return .optionSpace
            case .controlSpace:
                return .controlSpace
            case .commandShiftSpace:
                return .commandShiftSpace
            }
        }

        var modifierSide: ModifierSide {
            switch self {
            case .leftControl, .leftOption, .leftCommand, .leftShift:
                return .left
            case .rightControl, .rightOption, .rightCommand, .rightShift:
                return .right
            case .fn, .control, .option, .command, .shift, .f13, .f14, .f15, .f16, .f17, .f18, .f19,
                 .optionSpace, .controlSpace, .commandShiftSpace:
                return .either
            }
        }

        var registeredShortcut: (keyCode: UInt32, modifiers: UInt32)? {
            switch self {
            case .fn, .control, .leftControl, .rightControl,
                 .option, .leftOption, .rightOption,
                 .command, .leftCommand, .rightCommand,
                 .shift, .leftShift, .rightShift:
                return nil
            case .optionSpace:
                return (UInt32(kVK_Space), UInt32(optionKey))
            case .controlSpace:
                return (UInt32(kVK_Space), UInt32(controlKey))
            case .commandShiftSpace:
                return (UInt32(kVK_Space), UInt32(cmdKey | shiftKey))
            case .f13:
                return (UInt32(kVK_F13), 0)
            case .f14:
                return (UInt32(kVK_F14), 0)
            case .f15:
                return (UInt32(kVK_F15), 0)
            case .f16:
                return (UInt32(kVK_F16), 0)
            case .f17:
                return (UInt32(kVK_F17), 0)
            case .f18:
                return (UInt32(kVK_F18), 0)
            case .f19:
                return (UInt32(kVK_F19), 0)
            }
        }

        fileprivate var modifierTrigger: ModifierTrigger? {
            switch self {
            case .fn:
                return ModifierTrigger(flag: .function, sideMask: nil)
            case .control:
                return ModifierTrigger(flag: .control, sideMask: nil)
            case .leftControl:
                return ModifierTrigger(flag: .control, sideMask: ModifierSideMask.leftControl)
            case .rightControl:
                return ModifierTrigger(flag: .control, sideMask: ModifierSideMask.rightControl)
            case .option:
                return ModifierTrigger(flag: .option, sideMask: nil)
            case .leftOption:
                return ModifierTrigger(flag: .option, sideMask: ModifierSideMask.leftOption)
            case .rightOption:
                return ModifierTrigger(flag: .option, sideMask: ModifierSideMask.rightOption)
            case .command:
                return ModifierTrigger(flag: .command, sideMask: nil)
            case .leftCommand:
                return ModifierTrigger(flag: .command, sideMask: ModifierSideMask.leftCommand)
            case .rightCommand:
                return ModifierTrigger(flag: .command, sideMask: ModifierSideMask.rightCommand)
            case .shift:
                return ModifierTrigger(flag: .shift, sideMask: nil)
            case .leftShift:
                return ModifierTrigger(flag: .shift, sideMask: ModifierSideMask.leftShift)
            case .rightShift:
                return ModifierTrigger(flag: .shift, sideMask: ModifierSideMask.rightShift)
            case .f13, .f14, .f15, .f16, .f17, .f18, .f19,
                 .optionSpace, .controlSpace, .commandShiftSpace:
                return nil
            }
        }
    }

    fileprivate struct ModifierTrigger {
        let flag: NSEvent.ModifierFlags
        let sideMask: UInt

        init(flag: NSEvent.ModifierFlags, sideMask: UInt?) {
            self.flag = flag
            self.sideMask = sideMask ?? 0
        }

        var isSideSpecific: Bool {
            sideMask != 0
        }
    }

    fileprivate enum ModifierSideMask {
        static let leftControl: UInt = 0x0000_0001
        static let leftShift: UInt = 0x0000_0002
        static let rightShift: UInt = 0x0000_0004
        static let leftCommand: UInt = 0x0000_0008
        static let rightCommand: UInt = 0x0000_0010
        static let leftOption: UInt = 0x0000_0020
        static let rightOption: UInt = 0x0000_0040
        static let rightControl: UInt = 0x0000_2000
    }

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private static let hotkeySignature: OSType = 0x4854544B // "HTTK"
    private static let hotkeyID: UInt32 = 1

    private static let eventHandler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return noErr }
        let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
        manager.handle(eventKind: GetEventKind(event))
        return noErr
    }

    private var hotkey: Hotkey
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var globalModifierMonitor: Any?
    private var localModifierMonitor: Any?
    private var isStarted = false
    private var isDown = false

    init(hotkey: Hotkey = .fn) {
        self.hotkey = hotkey
    }

    deinit {
        stop()
    }

    func update(hotkey: Hotkey) {
        self.hotkey = hotkey
        guard isStarted else { return }
        unregisterHotKey()
        removeModifierMonitors()
        registerCurrentHotkey()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        registerCurrentHotkey()
    }

    func stop() {
        unregisterHotKey()
        removeModifierMonitors()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
        eventHandlerRef = nil
        isStarted = false
        isDown = false
    }

    private func registerCurrentHotkey() {
        isDown = false
        if hotkey.modifierTrigger != nil {
            installModifierMonitors()
        } else {
            installEventHandlerIfNeeded()
            registerHotKey()
        }
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventHandler,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        if status != noErr {
            debugLog("[hotkey] Failed to install event handler: \(status)")
            eventHandlerRef = nil
        }
    }

    private func registerHotKey() {
        guard let shortcut = hotkey.registeredShortcut else { return }

        let hotKeyID = EventHotKeyID(signature: Self.hotkeySignature, id: Self.hotkeyID)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status == noErr {
            debugLog("[hotkey] Registered \(hotkey.rawValue)")
        } else {
            hotKeyRef = nil
            debugLog("[hotkey] Failed to register \(hotkey.rawValue): \(status)")
        }
    }

    private func installModifierMonitors() {
        guard globalModifierMonitor == nil, localModifierMonitor == nil else { return }

        let mask: NSEvent.EventTypeMask = [.flagsChanged]
        globalModifierMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleModifierEvent(event)
        }
        localModifierMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleModifierEvent(event)
            return event
        }
        debugLog("[hotkey] Monitoring \(hotkey.rawValue) modifier flags")
    }

    private func removeModifierMonitors() {
        if let globalModifierMonitor {
            NSEvent.removeMonitor(globalModifierMonitor)
        }
        if let localModifierMonitor {
            NSEvent.removeMonitor(localModifierMonitor)
        }
        globalModifierMonitor = nil
        localModifierMonitor = nil
        isDown = false
    }

    private func unregisterHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        isDown = false
    }

    private func handle(eventKind: UInt32) {
        switch eventKind {
        case UInt32(kEventHotKeyPressed):
            guard !isDown else { return }
            isDown = true
            onPress?()
        case UInt32(kEventHotKeyReleased):
            guard isDown else { return }
            isDown = false
            onRelease?()
        default:
            break
        }
    }

    private func handleModifierEvent(_ event: NSEvent) {
        guard let trigger = hotkey.modifierTrigger else { return }

        let down: Bool
        if trigger.isSideSpecific {
            down = event.modifierFlags.rawValue & trigger.sideMask != 0
        } else {
            down = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .contains(trigger.flag)
        }

        if down {
            guard !isDown else { return }
            isDown = true
            onPress?()
        } else {
            guard isDown else { return }
            isDown = false
            onRelease?()
        }
    }
}
