import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

let postEventPromptedDefaultsKey = "hasPromptedPostEvent"
let stableCodeIdentityInfoPlistKey = "HTTStableCodeIdentity"

enum PermissionRequestResult: Equatable {
    case granted
    case prompted
    case openedSettings
}

/// Checks whether the app has keyboard-control access.
///
/// `CGPreflightPostEventAccess()` is known to cache its result for the lifetime of the
/// process. Once it returns `false`, it may keep returning `false` even after the user
/// grants permission in System Settings. Accessibility trust reflects the pane we ask
/// the user to enable and is a more reliable signal for ad-hoc local builds.
/// As a best-effort heuristic, we also attempt a test CGEvent post — if the system
/// silently accepts it, the permission is granted even though preflight still says no.
func checkPostEventAccess(
    preflight: () -> Bool = { CGPreflightPostEventAccess() },
    accessibilityTrusted: () -> Bool = { AXIsProcessTrusted() },
    postTestEvent: () -> Void = postNoOpMouseMoveEvent
) -> Bool {
    if preflight() { return true }
    if accessibilityTrusted() { return true }

    // Best-effort: try posting a no-visible-effect event (mouse-move to current position).
    // Check both signals again afterward in case the post refreshed cached state.
    postTestEvent()
    return preflight() || accessibilityTrusted()
}

private func postNoOpMouseMoveEvent() {
    guard let event = CGEvent(source: nil) else { return }
    event.type = .mouseMoved
    event.post(tap: .cghidEventTap)
}

/// Relaunches the app. Used when PostEvent permission is granted in System Settings
/// but `CGPreflightPostEventAccess()` still returns a stale `false`.
/// This is only useful when the current app has a stable code identity.
func relaunchApp() {
    let url = Bundle.main.bundleURL
    let config = NSWorkspace.OpenConfiguration()
    config.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}

func appHasStableCodeIdentity(infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> Bool {
    infoDictionary[stableCodeIdentityInfoPlistKey] as? Bool ?? false
}

/// Opens the specified System Settings / System Preferences privacy pane.
///
/// Tries the legacy `com.apple.preference.security` URL first, then the
/// macOS 15+ `com.apple.settings.PrivacySecurity.extension` variant, and
/// falls back to the top-level Security & Privacy pane.
func openSystemSettings(_ anchor: String) {
    let urls = [
        "x-apple.systempreferences:com.apple.preference.security?\(anchor)",
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)",
    ]
    for str in urls {
        if let url = URL(string: str), NSWorkspace.shared.open(url) {
            return
        }
    }
    if let fallback = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
        NSWorkspace.shared.open(fallback)
    }
}

func isSystemSettingsApplication(_ application: NSRunningApplication?) -> Bool {
    guard let application else { return false }
    if application.bundleIdentifier == "com.apple.systempreferences" {
        return true
    }
    return ["System Settings", "System Preferences"].contains(application.localizedName ?? "")
}

@discardableResult
func requestPostEventAccess(
    defaults: UserDefaults = .standard,
    preflight: () -> Bool = { checkPostEventAccess() },
    requestAccess: () -> Bool = CGRequestPostEventAccess,
    settingsOpener: (String) -> Void = openSystemSettings
) -> PermissionRequestResult {
    requestPrivacyPermissionAccess(
        defaults: defaults,
        promptedDefaultsKey: postEventPromptedDefaultsKey,
        settingsAnchor: "Privacy_Accessibility",
        preflight: preflight,
        requestAccess: requestAccess,
        settingsOpener: settingsOpener
    )
}

private func requestPrivacyPermissionAccess(
    defaults: UserDefaults,
    promptedDefaultsKey: String,
    settingsAnchor: String,
    preflight: () -> Bool,
    requestAccess: () -> Bool,
    settingsOpener: (String) -> Void
) -> PermissionRequestResult {
    if preflight() {
        return .granted
    }

    if defaults.bool(forKey: promptedDefaultsKey) {
        settingsOpener(settingsAnchor)
        return .openedSettings
    }

    let granted = requestAccess()
    defaults.set(true, forKey: promptedDefaultsKey)
    if granted || preflight() {
        return .granted
    }

    // Some macOS builds do not present a visible sheet here, so fall through to the
    // exact Settings pane on the first click instead of making the user click again.
    settingsOpener(settingsAnchor)
    return .openedSettings
}
