import AppKit

/// Inserts text at the focused caret.
enum TextInserter {
    enum FailureReason {
        case secureInput
        case wrongTargetApp
        case shellTargetNotConfirmed

        var userFacingError: String {
            switch self {
            case .secureInput:
                return "Secure text input is active. Dictation is unavailable in password and other protected fields."
            case .wrongTargetApp:
                return "Could not focus the app you were dictating into. Switch back to that app and try again."
            case .shellTargetNotConfirmed:
                return "Dictation into terminal apps requires confirmation before text is inserted."
            }
        }
    }

    struct InsertReport {
        let success: Bool
        let confirmed: Bool
        let method: String?
        let attempts: [String]
        let failureReason: FailureReason?

        var summary: String {
            if let failureReason {
                return "Insert blocked. \(failureReason.userFacingError) " + attempts.joined(separator: " | ")
            }
            if success, confirmed, let method {
                return "Inserted via \(method)."
            }
            if let method {
                return "Insertion unconfirmed via \(method). " + attempts.joined(separator: " | ")
            }
            return "Insert failed. " + attempts.joined(separator: " | ")
        }

        var userFacingError: String? {
            if let failureReason {
                return failureReason.userFacingError
            }
            if !confirmed {
                return "Text insertion could not be confirmed. Check the target app and try again."
            }
            return nil
        }
    }

    private enum Strategy: String {
        case keycodeTyping = "keycodeTyping"
        case unicodeChunked = "unicodeChunked"
        case syntheticTyping = "syntheticTyping"
        case clipboardPaste = "clipboardPaste"
    }

    private enum StrategyOutcome {
        case success
        case tentative
        case fail
    }

    private struct Profile {
        let name: String
        let order: [Strategy]
        let passes: Int
        let typingCharDelayMicros: useconds_t
    }

    static func insert(
        _ text: String,
        targetBundleID: String? = nil,
        targetPID: pid_t? = nil
    ) -> InsertReport {
        guard !text.isEmpty else {
            return InsertReport(
                success: false,
                confirmed: false,
                method: nil,
                attempts: ["empty text"],
                failureReason: nil
            )
        }

        var attempts: [String] = []
        if let targetPID {
            let focus = ensureTargetAppFocused(pid: targetPID, bundleID: targetBundleID)
            attempts.append(focus.attempt)
            if !focus.ready {
                return InsertReport(
                    success: false,
                    confirmed: false,
                    method: nil,
                    attempts: attempts,
                    failureReason: .wrongTargetApp
                )
            }
        }

        let bundleID = targetBundleID ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        let profile = profile(for: bundleID)
        attempts.append("app=\(bundleID)")
        attempts.append("profile=\(profile.name)")
        if Self.requiresShellTargetConfirmation(bundleID: bundleID) {
            attempts.append("shellTarget=requiresConfirmation")
            guard Self.confirmShellTargetInsertion(bundleID: bundleID) else {
                attempts.append("blocked=shellTarget")
                return InsertReport(
                    success: false,
                    confirmed: false,
                    method: nil,
                    attempts: attempts,
                    failureReason: .shellTargetNotConfirmed
                )
            }
            attempts.append("shellTarget=confirmed")
        }
        attempts.append("PostEvent: \(checkPostEventAccess() ? "yes" : "no")")
        let secureInputActive = isSecureInputActive()
        attempts.append("secureInput=\(secureInputActive ? "on" : "off")")
        if secureInputActive {
            attempts.append("blocked=secureInput")
            return InsertReport(
                success: false,
                confirmed: false,
                method: nil,
                attempts: attempts,
                failureReason: .secureInput
            )
        }

        for pass in 0..<max(1, profile.passes) {
            for strategy in profile.order {
                switch run(
                    strategy: strategy,
                    text: text,
                    typingCharDelayMicros: profile.typingCharDelayMicros
                ) {
                case .success:
                    attempts.append("pass\(pass + 1):\(strategy.rawValue)=ok")
                    return InsertReport(
                        success: true,
                        confirmed: true,
                        method: strategy.rawValue,
                        attempts: attempts,
                        failureReason: nil
                    )
                case .tentative:
                    attempts.append("pass\(pass + 1):\(strategy.rawValue)=tentative")
                    return InsertReport(
                        success: true,
                        confirmed: true,
                        method: strategy.rawValue,
                        attempts: attempts,
                        failureReason: nil
                    )
                case .fail:
                    attempts.append("pass\(pass + 1):\(strategy.rawValue)=fail")
                }
            }
            usleep(35_000)
        }

        return InsertReport(success: false, confirmed: false, method: nil, attempts: attempts, failureReason: nil)
    }

    private static func ensureTargetAppFocused(pid: pid_t, bundleID: String?) -> (ready: Bool, attempt: String) {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return (false, "targetApp=notRunning")
        }
        if app.bundleIdentifier == Bundle.main.bundleIdentifier {
            return (false, "targetApp=self")
        }

        for attempt in 1...4 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                if let bundleID, NSWorkspace.shared.frontmostApplication?.bundleIdentifier != bundleID {
                    return (false, "targetApp=bundleMismatch")
                }
                return (true, "targetApp=focused")
            }
            app.activate()
            usleep(40_000)
            if attempt < 4 {
                continue
            }
        }

        return (false, "targetApp=focusFailed")
    }

    static func requiresShellTargetConfirmation(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return shellTargetBundleIDs.contains(bundleID)
    }

    private static func confirmShellTargetInsertion(bundleID: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Insert dictation into terminal?"
        alert.informativeText = """
        The focused app is a terminal-like app (\(bundleID)). Dictated text can execute as shell commands if it lands at a prompt.
        """
        alert.addButton(withTitle: "Insert")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func run(
        strategy: Strategy,
        text: String,
        typingCharDelayMicros: useconds_t
    ) -> StrategyOutcome {
        switch strategy {
        case .keycodeTyping:
            return insertViaKeycodeTyping(text, charDelayMicros: typingCharDelayMicros) ? .tentative : .fail
        case .unicodeChunked:
            return insertViaUnicodeChunks(text, charDelayMicros: typingCharDelayMicros) ? .tentative : .fail
        case .syntheticTyping:
            return insertViaSyntheticTyping(text, charDelayMicros: typingCharDelayMicros) ? .tentative : .fail
        case .clipboardPaste:
            return insertViaClipboardPaste(text) ? .tentative : .fail
        }
    }

    private static func profile(for bundleID: String) -> Profile {
        // Electron apps duplicate text when receiving unicode chunks — use clipboard paste.
        let electronPrefixes = [
            "com.cursor.",
            "com.todesktop.",
            "com.microsoft.VSCode",
            "com.tinyspeck.slackmacgap",
            "notion.id",
            "md.obsidian",
        ]
        if electronPrefixes.contains(where: { bundleID.hasPrefix($0) }) {
            return Profile(
                name: "electron-paste",
                order: [.clipboardPaste, .unicodeChunked, .syntheticTyping],
                passes: 1,
                typingCharDelayMicros: 4_000
            )
        }

        // Browsers: clipboard paste first, then fall back to typing.
        let browserPrefixes = [
            "com.google.Chrome",
            "com.brave.Browser",
            "org.mozilla.firefox",
            "com.apple.Safari",
        ]
        if browserPrefixes.contains(where: { bundleID.hasPrefix($0) }) {
            return Profile(
                name: "browser-paste",
                order: [.clipboardPaste, .unicodeChunked, .syntheticTyping],
                passes: 1,
                typingCharDelayMicros: 5_000
            )
        }

        // Native macOS apps: unicode chunks work reliably.
        return Profile(
            name: "default",
            order: [.unicodeChunked, .keycodeTyping, .syntheticTyping, .clipboardPaste],
            passes: 2,
            typingCharDelayMicros: 800
        )
    }

    private static func insertViaSyntheticTyping(_ text: String, charDelayMicros: useconds_t) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }
        for scalar in text.unicodeScalars {
            var utf16Units = Array(String(scalar).utf16)
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                return false
            }
            keyDown.keyboardSetUnicodeString(stringLength: utf16Units.count, unicodeString: &utf16Units)
            keyUp.keyboardSetUnicodeString(stringLength: utf16Units.count, unicodeString: &utf16Units)
            postKeyEvent(keyDown)
            postKeyEvent(keyUp)
            if charDelayMicros > 0 {
                usleep(charDelayMicros)
            }
        }
        return true
    }

    private static func insertViaKeycodeTyping(_ text: String, charDelayMicros: useconds_t) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }

        for ch in text {
            if let entry = keyMap[ch] {
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: entry.keyCode, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: entry.keyCode, keyDown: false) else {
                    return false
                }
                down.flags = entry.flags
                up.flags = entry.flags
                postKeyEvent(down)
                postKeyEvent(up)
            } else {
                // Fix #11: fall back to unicode injection for unmapped characters (non-ASCII, accented, etc.)
                var utf16Units = Array(String(ch).utf16)
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                    return false
                }
                down.keyboardSetUnicodeString(stringLength: utf16Units.count, unicodeString: &utf16Units)
                up.keyboardSetUnicodeString(stringLength: utf16Units.count, unicodeString: &utf16Units)
                postKeyEvent(down)
                postKeyEvent(up)
            }
            if charDelayMicros > 0 { usleep(charDelayMicros) }
        }
        return true
    }

    private static func insertViaUnicodeChunks(_ text: String, charDelayMicros: useconds_t) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }

        // Mirrors proven text expanders: send unicode in bounded chunks to avoid truncation/ignore cases.
        let utf16 = Array(text.utf16)
        guard !utf16.isEmpty else { return false }
        let chunkSize = 20

        // If shift is physically held, injected unicode can behave unpredictably.
        if CGEventSource.keyState(.hidSystemState, key: 0x38),
           let shiftUp = CGEvent(keyboardEventSource: source, virtualKey: 0x38, keyDown: false) {
            postKeyEvent(shiftUp)
            usleep(max(charDelayMicros, 3_000))
        }

        // Use virtual key 0 (kVK_ANSI_A) instead of 0x31 (space bar) as the carrier key.
        // Electron apps can interpret the space bar keypress independently of the unicode
        // payload, causing duplicate text insertion for later chunks.
        let carrierKey: CGKeyCode = 0

        var index = 0
        while index < utf16.count {
            let end = min(index + chunkSize, utf16.count)
            var chunk = Array(utf16[index..<end])

            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: carrierKey, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: carrierKey, keyDown: false) else {
                return false
            }
            // Unicode payload on keyDown only.
            keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            // Clear unicode on keyUp so the app doesn't re-process the payload on key release.
            var empty: [UniChar] = []
            keyUp.keyboardSetUnicodeString(stringLength: 0, unicodeString: &empty)
            postKeyEvent(keyDown)
            usleep(max(charDelayMicros, 4_000))
            postKeyEvent(keyUp)

            if charDelayMicros > 0 {
                usleep(charDelayMicros)
            }
            index = end
        }
        return true
    }

    private static func insertViaClipboardPaste(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        let originalChangeCount = pasteboard.changeCount

        // Fix #12: preserve ALL types from each item, not just the first
        let savedItems: [SavedItem] = pasteboard.pasteboardItems?.map { item in
            let pairs = item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            }
            return SavedItem(types: pairs)
        } ?? []

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let insertionChangeCount = pasteboard.changeCount

        // Simulate CMD+V (virtual key 0x09 = 'v')
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: false) else {
            restoreClipboard(pasteboard, items: savedItems)
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)

        // Give the target app time to read the pasteboard before restoring it.
        var waited: useconds_t = 0
        let step: useconds_t = 25_000
        let maxWait: useconds_t = 500_000
        while waited < maxWait {
            usleep(step)
            waited += step
        }
        if pasteboard.changeCount == insertionChangeCount {
            restoreClipboard(pasteboard, items: savedItems)
        } else {
            debugLog("[holdtotalk] Clipboard changed during paste insertion; leaving current clipboard untouched. originalChangeCount=\(originalChangeCount)")
        }
        return true
    }

    private struct SavedItem {
        let types: [(NSPasteboard.PasteboardType, Data)]
    }

    private static func restoreClipboard(_ pasteboard: NSPasteboard, items: [SavedItem]) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        // Fix #12: restore each item with all its original types
        let pbItems = items.map { saved -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in saved.types {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(pbItems)
    }

    private struct KeyEntry {
        let keyCode: CGKeyCode
        let flags: CGEventFlags
    }

    private static let shellTargetBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.github.wez.wezterm",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp-Preview",
        "co.zeit.hyper",
        "org.tabby",
    ]

    /// Returns whether secure event input is active (e.g. password fields).
    /// Uses CGEventSource instead of dlopen(Carbon) so it works inside the App Store sandbox.
    private static func isSecureInputActive() -> Bool {
        // When secure input is enabled by another process, CGEventSource creation
        // for .combinedSessionState fails (returns nil) — use that as the signal.
        // Additionally, a suppression interval of 0 indicates secure input is active.
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return true }
        return src.localEventsSuppressionInterval == 0
    }

    private static let keyMap: [Character: KeyEntry] = [
        "a": .init(keyCode: 0, flags: []), "A": .init(keyCode: 0, flags: .maskShift),
        "b": .init(keyCode: 11, flags: []), "B": .init(keyCode: 11, flags: .maskShift),
        "c": .init(keyCode: 8, flags: []), "C": .init(keyCode: 8, flags: .maskShift),
        "d": .init(keyCode: 2, flags: []), "D": .init(keyCode: 2, flags: .maskShift),
        "e": .init(keyCode: 14, flags: []), "E": .init(keyCode: 14, flags: .maskShift),
        "f": .init(keyCode: 3, flags: []), "F": .init(keyCode: 3, flags: .maskShift),
        "g": .init(keyCode: 5, flags: []), "G": .init(keyCode: 5, flags: .maskShift),
        "h": .init(keyCode: 4, flags: []), "H": .init(keyCode: 4, flags: .maskShift),
        "i": .init(keyCode: 34, flags: []), "I": .init(keyCode: 34, flags: .maskShift),
        "j": .init(keyCode: 38, flags: []), "J": .init(keyCode: 38, flags: .maskShift),
        "k": .init(keyCode: 40, flags: []), "K": .init(keyCode: 40, flags: .maskShift),
        "l": .init(keyCode: 37, flags: []), "L": .init(keyCode: 37, flags: .maskShift),
        "m": .init(keyCode: 46, flags: []), "M": .init(keyCode: 46, flags: .maskShift),
        "n": .init(keyCode: 45, flags: []), "N": .init(keyCode: 45, flags: .maskShift),
        "o": .init(keyCode: 31, flags: []), "O": .init(keyCode: 31, flags: .maskShift),
        "p": .init(keyCode: 35, flags: []), "P": .init(keyCode: 35, flags: .maskShift),
        "q": .init(keyCode: 12, flags: []), "Q": .init(keyCode: 12, flags: .maskShift),
        "r": .init(keyCode: 15, flags: []), "R": .init(keyCode: 15, flags: .maskShift),
        "s": .init(keyCode: 1, flags: []), "S": .init(keyCode: 1, flags: .maskShift),
        "t": .init(keyCode: 17, flags: []), "T": .init(keyCode: 17, flags: .maskShift),
        "u": .init(keyCode: 32, flags: []), "U": .init(keyCode: 32, flags: .maskShift),
        "v": .init(keyCode: 9, flags: []), "V": .init(keyCode: 9, flags: .maskShift),
        "w": .init(keyCode: 13, flags: []), "W": .init(keyCode: 13, flags: .maskShift),
        "x": .init(keyCode: 7, flags: []), "X": .init(keyCode: 7, flags: .maskShift),
        "y": .init(keyCode: 16, flags: []), "Y": .init(keyCode: 16, flags: .maskShift),
        "z": .init(keyCode: 6, flags: []), "Z": .init(keyCode: 6, flags: .maskShift),
        "0": .init(keyCode: 29, flags: []), ")": .init(keyCode: 29, flags: .maskShift),
        "1": .init(keyCode: 18, flags: []), "!": .init(keyCode: 18, flags: .maskShift),
        "2": .init(keyCode: 19, flags: []), "@": .init(keyCode: 19, flags: .maskShift),
        "3": .init(keyCode: 20, flags: []), "#": .init(keyCode: 20, flags: .maskShift),
        "4": .init(keyCode: 21, flags: []), "$": .init(keyCode: 21, flags: .maskShift),
        "5": .init(keyCode: 23, flags: []), "%": .init(keyCode: 23, flags: .maskShift),
        "6": .init(keyCode: 22, flags: []), "^": .init(keyCode: 22, flags: .maskShift),
        "7": .init(keyCode: 26, flags: []), "&": .init(keyCode: 26, flags: .maskShift),
        "8": .init(keyCode: 28, flags: []), "*": .init(keyCode: 28, flags: .maskShift),
        "9": .init(keyCode: 25, flags: []), "(": .init(keyCode: 25, flags: .maskShift),
        " ": .init(keyCode: 49, flags: []), "\n": .init(keyCode: 36, flags: []),
        ".": .init(keyCode: 47, flags: []), ">": .init(keyCode: 47, flags: .maskShift),
        ",": .init(keyCode: 43, flags: []), "<": .init(keyCode: 43, flags: .maskShift),
        "?": .init(keyCode: 44, flags: .maskShift), "/": .init(keyCode: 44, flags: []),
        "-": .init(keyCode: 27, flags: []), "_": .init(keyCode: 27, flags: .maskShift),
        "=": .init(keyCode: 24, flags: []), "+": .init(keyCode: 24, flags: .maskShift),
        "'": .init(keyCode: 39, flags: []), "\"": .init(keyCode: 39, flags: .maskShift),
        ";": .init(keyCode: 41, flags: []), ":": .init(keyCode: 41, flags: .maskShift),
    ]

    private static func postKeyEvent(_ event: CGEvent) {
        event.post(tap: .cghidEventTap)
    }

}
