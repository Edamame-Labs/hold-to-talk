import AVFoundation
import Foundation

let onboardingCompleteDefaultsKey = "onboardingComplete"
let onboardingStepDefaultsKey = "onboardingStep"
let onboardingCompletedAppPathDefaultsKey = "onboardingCompletedAppPath"
let onboardingCompletedAppVersionDefaultsKey = "onboardingCompletedAppVersion"
let permissionsStaleAfterUpdateDefaultsKey = "permissionsStaleAfterUpdate"
let onboardingNeedsResumeAfterAppMoveDefaultsKey = "onboardingNeedsResumeAfterAppMove"
let dismissedInstallPromptDefaultsKey = "dismissedInstallPrompt"
let whisperModelDefaultsKey = "whisperModel"
let transcriptionProfileDefaultsKey = "transcriptionProfile"
let hotkeyChoiceDefaultsKey = "hotkeyChoice"
let diagnosticLoggingEnabledDefaultsKey = "diagnosticLoggingEnabled"
let textCleanupEnabledDefaultsKey = "textCleanupEnabled"
let textCleanupPromptDefaultsKey = "textCleanupPrompt"
let hotwordsDefaultsKey = "hotwords"
let recordingHUDPositionDefaultsKey = "recordingHUDPosition"
let preferredInputDeviceUIDDefaultsKey = "preferredInputDeviceUID"
let launchAtLoginDefaultsKey = "launchAtLogin"
let transcriptionProviderDefaultsKey = "transcriptionProvider"
let cleanupProviderDefaultsKey = "cleanupProvider"
let dictationLanguageModeDefaultsKey = "dictationLanguageMode"
let cleanupStylingDefaultsKey = "cleanupStyling"
let cleanupStructureDefaultsKey = "cleanupStructure"
let openaiTranscriptionModelDefaultsKey = "openaiTranscriptionModel"
let openaiCleanupModelDefaultsKey = "openaiCleanupModel"
let anthropicCleanupModelDefaultsKey = "anthropicCleanupModel"
let openaiBaseURLDefaultsKey = "openaiBaseURL"
let anthropicBaseURLDefaultsKey = "anthropicBaseURL"
let openaiAPIKeySavedDefaultsKey = "openaiAPIKeySaved"
let anthropicAPIKeySavedDefaultsKey = "anthropicAPIKeySaved"

enum OnboardingLaunchPreparation: Equatable {
    case none
    case fullReset
    case reopenAfterAppMove
}

func shouldResetAppStateForFreshOnboarding(defaults: UserDefaults = .standard) -> Bool {
    #if DEBUG
    if DebugFlags.resetOnboarding {
        return true
    }
    #endif
    return false
}

func onboardingLaunchPreparation(
    defaults: UserDefaults = .standard,
    currentAppURL: URL = Bundle.main.bundleURL,
    currentAppVersion: String = currentAppShortVersion(),
    environmentReady: (UserDefaults) -> Bool = { completedOnboardingEnvironmentReady(defaults: $0) }
) -> OnboardingLaunchPreparation {
    #if DEBUG
    if DebugFlags.resetOnboarding {
        return .fullReset
    }
    #endif

    if defaults.bool(forKey: onboardingNeedsResumeAfterAppMoveDefaultsKey) {
        return .reopenAfterAppMove
    }

    if !defaults.bool(forKey: onboardingCompleteDefaultsKey) {
        return .none
    }

    let currentPath = normalizedAppBundlePath(currentAppURL)
    if let storedPath = defaults.string(forKey: onboardingCompletedAppPathDefaultsKey) {
        let storedVersion = defaults.string(forKey: onboardingCompletedAppVersionDefaultsKey)
        let movedApp = storedPath != currentPath
        // A Sparkle or drag install replaces the bundle at the same path, so the
        // path alone cannot tell us an update happened. Without the version we
        // would skip the permission check on exactly the upgrades that break it.
        let updatedApp = storedVersion != currentAppVersion

        if !movedApp && !updatedApp { return .none }

        // App was moved or updated. If all permissions are still granted
        // and the selected transcription provider is ready, just update the
        // stored identity and skip onboarding entirely.
        if environmentReady(defaults) {
            rememberOnboardingInstallIdentity(
                defaults: defaults,
                path: currentPath,
                version: currentAppVersion
            )
            defaults.removeObject(forKey: permissionsStaleAfterUpdateDefaultsKey)
            return .none
        }

        // Permissions read as missing right after the app moved or updated.
        // macOS often keeps the previous entry listed and switched on while the
        // grant itself no longer matches, so the usual "enable it" guidance is
        // wrong here — flag it so the UI can say to remove and re-add instead.
        defaults.set(true, forKey: permissionsStaleAfterUpdateDefaultsKey)
        return .reopenAfterAppMove
    }

    // Existing installs from older builds should keep working without forcing onboarding again.
    rememberOnboardingInstallIdentity(
        defaults: defaults,
        path: currentPath,
        version: currentAppVersion
    )
    return .none
}

/// Short version string of the running bundle, used to notice in-place updates.
func currentAppShortVersion(bundle: Bundle = .main) -> String {
    bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
}

private func rememberOnboardingInstallIdentity(
    defaults: UserDefaults,
    path: String,
    version: String
) {
    defaults.set(path, forKey: onboardingCompletedAppPathDefaultsKey)
    defaults.set(version, forKey: onboardingCompletedAppVersionDefaultsKey)
}

/// Whether the last launch found permissions missing straight after the app was
/// moved or updated — the signature of a stale TCC entry rather than a grant the
/// user never gave.
func permissionsLikelyStaleAfterUpdate(defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: permissionsStaleAfterUpdateDefaultsKey)
}

func clearStalePermissionFlag(defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: permissionsStaleAfterUpdateDefaultsKey)
}

/// TCC services this app holds grants for.
///
/// `PostEvent` is the one that actually gates text insertion —
/// `CGPreflightPostEventAccess` reads it — even though System Settings shows it
/// under the Accessibility pane. `ListenEvent` covers the bare-modifier hotkey
/// monitoring. Leaving either out makes the reset look like it did nothing.
let tccServicesUsedByApp = ["Microphone", "Accessibility", "PostEvent", "ListenEvent"]

/// Commands that clear this app's TCC grants. An app cannot reset its own
/// entries — there is no API for it — so the user has to run these in Terminal
/// when removing and re-adding the app in System Settings is not enough.
func tccResetCommand(
    bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.holdtotalk.app",
    services: [String] = tccServicesUsedByApp
) -> String {
    services
        .map { "tccutil reset \($0) \(bundleIdentifier)" }
        .joined(separator: "; ")
}

func rememberCompletedOnboardingForCurrentInstall(
    defaults: UserDefaults = .standard,
    currentAppURL: URL = Bundle.main.bundleURL,
    currentAppVersion: String = currentAppShortVersion()
) {
    defaults.set(true, forKey: onboardingCompleteDefaultsKey)
    defaults.removeObject(forKey: onboardingNeedsResumeAfterAppMoveDefaultsKey)
    defaults.removeObject(forKey: permissionsStaleAfterUpdateDefaultsKey)
    rememberOnboardingInstallIdentity(
        defaults: defaults,
        path: normalizedAppBundlePath(currentAppURL),
        version: currentAppVersion
    )
}

func prepareOnboardingToResumeAfterAppMove(defaults: UserDefaults = .standard) {
    defaults.set(true, forKey: onboardingNeedsResumeAfterAppMoveDefaultsKey)
    defaults.set(1, forKey: onboardingStepDefaultsKey)
}

func cancelOnboardingResumeAfterFailedAppMove(defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: onboardingNeedsResumeAfterAppMoveDefaultsKey)
    defaults.set(0, forKey: onboardingStepDefaultsKey)
}

func reopenOnboardingForCurrentInstall(
    defaults: UserDefaults = .standard,
    currentAppURL: URL = Bundle.main.bundleURL,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
) {
    defaults.set(false, forKey: onboardingCompleteDefaultsKey)
    defaults.set(true, forKey: onboardingNeedsResumeAfterAppMoveDefaultsKey)
    defaults.set(
        isInstalledInApplicationsFolder(appURL: currentAppURL, homeDirectory: homeDirectory) ? 1 : 0,
        forKey: onboardingStepDefaultsKey
    )
    defaults.removeObject(forKey: postEventPromptedDefaultsKey)
    defaults.set(normalizedAppBundlePath(currentAppURL), forKey: onboardingCompletedAppPathDefaultsKey)
}

func holdToTalkApplicationSupportDirectory(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
) -> URL {
    homeDirectory
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Application Support", isDirectory: true)
        .appendingPathComponent("HoldToTalk", isDirectory: true)
}

func holdToTalkCacheDirectories(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.holdtotalk.app"
) -> [URL] {
    let cachesRoot = homeDirectory
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Caches", isDirectory: true)

    return [
        cachesRoot.appendingPathComponent("HoldToTalk", isDirectory: true),
        cachesRoot.appendingPathComponent(bundleIdentifier, isDirectory: true),
    ]
}

func resetPersistedAppStateForFreshOnboarding(
    defaults: UserDefaults = .standard,
    bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.holdtotalk.app",
    fileManager: FileManager = .default,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
) {
    defaults.removePersistentDomain(forName: bundleIdentifier)
    defaults.synchronize()

    let appSupportDirectory = holdToTalkApplicationSupportDirectory(homeDirectory: homeDirectory)
    if fileManager.fileExists(atPath: appSupportDirectory.path) {
        if let contents = try? fileManager.contentsOfDirectory(
            at: appSupportDirectory,
            includingPropertiesForKeys: nil
        ) {
            for child in contents {
                try? fileManager.removeItem(at: child)
            }
        } else {
            try? fileManager.removeItem(at: appSupportDirectory)
        }
    }

    try? fileManager.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)

    for cacheDirectory in holdToTalkCacheDirectories(
        homeDirectory: homeDirectory,
        bundleIdentifier: bundleIdentifier
    ) {
        guard fileManager.fileExists(atPath: cacheDirectory.path) else { continue }
        try? fileManager.removeItem(at: cacheDirectory)
    }
}

func completedOnboardingEnvironmentReady(defaults: UserDefaults = .standard) -> Bool {
    guard checkPostEventAccess() else { return false }
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return false }
    if completedOnboardingRequiresLocalModel(defaults: defaults) {
        return ModelManager.isModelDownloaded
    }
    return true
}

func completedOnboardingRequiresLocalModel(defaults: UserDefaults = .standard) -> Bool {
    let providerRawValue = defaults.string(forKey: transcriptionProviderDefaultsKey)
        ?? TranscriptionProvider.local.rawValue
    return (TranscriptionProvider(rawValue: providerRawValue) ?? .local) == .local
}

private func normalizedAppBundlePath(_ appURL: URL) -> String {
    appURL.resolvingSymlinksInPath().standardizedFileURL.path
}
