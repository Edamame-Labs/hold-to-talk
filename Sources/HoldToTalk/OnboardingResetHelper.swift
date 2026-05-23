import AVFoundation
import Foundation

let onboardingCompleteDefaultsKey = "onboardingComplete"
let onboardingStepDefaultsKey = "onboardingStep"
let onboardingCompletedAppPathDefaultsKey = "onboardingCompletedAppPath"
let onboardingNeedsResumeAfterAppMoveDefaultsKey = "onboardingNeedsResumeAfterAppMove"
let dismissedInstallPromptDefaultsKey = "dismissedInstallPrompt"
let whisperModelDefaultsKey = "whisperModel"
let transcriptionProfileDefaultsKey = "transcriptionProfile"
let hotkeyChoiceDefaultsKey = "hotkeyChoice"
let diagnosticLoggingEnabledDefaultsKey = "diagnosticLoggingEnabled"
let textCleanupEnabledDefaultsKey = "textCleanupEnabled"
let textCleanupPromptDefaultsKey = "textCleanupPrompt"
let hotwordsDefaultsKey = "hotwords"
let launchAtLoginDefaultsKey = "launchAtLogin"
let transcriptionProviderDefaultsKey = "transcriptionProvider"
let cleanupProviderDefaultsKey = "cleanupProvider"
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
    currentAppURL: URL = Bundle.main.bundleURL
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
        if storedPath == currentPath { return .none }

        // App was moved or updated. If all permissions are still granted
        // and the selected transcription provider is ready, just update the
        // stored path and skip onboarding entirely.
        if completedOnboardingEnvironmentReady(defaults: defaults) {
            defaults.set(currentPath, forKey: onboardingCompletedAppPathDefaultsKey)
            return .none
        }

        return .reopenAfterAppMove
    }

    // Existing installs from older builds should keep working without forcing onboarding again.
    defaults.set(currentPath, forKey: onboardingCompletedAppPathDefaultsKey)
    return .none
}

func rememberCompletedOnboardingForCurrentInstall(
    defaults: UserDefaults = .standard,
    currentAppURL: URL = Bundle.main.bundleURL
) {
    defaults.set(true, forKey: onboardingCompleteDefaultsKey)
    defaults.removeObject(forKey: onboardingNeedsResumeAfterAppMoveDefaultsKey)
    defaults.set(normalizedAppBundlePath(currentAppURL), forKey: onboardingCompletedAppPathDefaultsKey)
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
