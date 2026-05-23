import XCTest
@testable import HoldToTalk

final class OnboardingResetHelperTests: XCTestCase {
    func testOnboardingLaunchPreparationResumesWhenOnboardingIncomplete() {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }

        defaults.set(false, forKey: onboardingCompleteDefaultsKey)
        defaults.set(2, forKey: onboardingStepDefaultsKey)

        XCTAssertEqual(
            onboardingLaunchPreparation(
                defaults: defaults,
                currentAppURL: URL(fileURLWithPath: "/Applications/HoldToTalk.app", isDirectory: true)
            ),
            .none
        )
        XCTAssertEqual(defaults.integer(forKey: onboardingStepDefaultsKey), 2)
    }

    func testOnboardingLaunchPreparationStoresPathForExistingCompletedInstall() {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }

        let appURL = URL(fileURLWithPath: "/Applications/HoldToTalk.app", isDirectory: true)
        defaults.set(true, forKey: onboardingCompleteDefaultsKey)

        XCTAssertEqual(
            onboardingLaunchPreparation(defaults: defaults, currentAppURL: appURL),
            .none
        )
        XCTAssertEqual(
            defaults.string(forKey: onboardingCompletedAppPathDefaultsKey),
            appURL.path
        )
    }

    func testOnboardingLaunchPreparationReopensOnboardingAfterAppMove() {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }

        defaults.set(true, forKey: onboardingCompleteDefaultsKey)
        defaults.set(
            "/Volumes/HoldToTalk/HoldToTalk.app",
            forKey: onboardingCompletedAppPathDefaultsKey
        )

        XCTAssertEqual(
            onboardingLaunchPreparation(
                defaults: defaults,
                currentAppURL: URL(fileURLWithPath: "/Applications/HoldToTalk.app", isDirectory: true)
            ),
            .reopenAfterAppMove
        )
    }

    func testShouldNotResetAppStateForFreshOnboardingWhenOnboardingIncomplete() {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }

        defaults.set(false, forKey: onboardingCompleteDefaultsKey)

        XCTAssertFalse(shouldResetAppStateForFreshOnboarding(defaults: defaults))
    }

    func testShouldNotResetAppStateForFreshOnboardingWhenOnboardingComplete() {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }

        defaults.set(true, forKey: onboardingCompleteDefaultsKey)

        XCTAssertFalse(shouldResetAppStateForFreshOnboarding(defaults: defaults))
    }

    func testShouldNotResetAppStateForFreshOnboardingWhenResumingAfterAppMove() {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }

        defaults.set(false, forKey: onboardingCompleteDefaultsKey)
        defaults.set(true, forKey: onboardingNeedsResumeAfterAppMoveDefaultsKey)

        XCTAssertFalse(shouldResetAppStateForFreshOnboarding(defaults: defaults))
    }

    func testReopenOnboardingForCurrentInstallResetsPermissionFlowWithoutWipingSettings() {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }

        defaults.set(true, forKey: onboardingCompleteDefaultsKey)
        defaults.set(3, forKey: onboardingStepDefaultsKey)
        defaults.set(true, forKey: postEventPromptedDefaultsKey)
        defaults.set("small", forKey: whisperModelDefaultsKey)
        defaults.set("option_space", forKey: hotkeyChoiceDefaultsKey)

        let appURL = URL(fileURLWithPath: "/Applications/HoldToTalk.app", isDirectory: true)
        reopenOnboardingForCurrentInstall(
            defaults: defaults,
            currentAppURL: appURL,
            homeDirectory: URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        )

        XCTAssertFalse(defaults.bool(forKey: onboardingCompleteDefaultsKey))
        XCTAssertTrue(defaults.bool(forKey: onboardingNeedsResumeAfterAppMoveDefaultsKey))
        XCTAssertEqual(defaults.integer(forKey: onboardingStepDefaultsKey), 1)
        XCTAssertFalse(defaults.bool(forKey: postEventPromptedDefaultsKey))
        XCTAssertEqual(defaults.string(forKey: whisperModelDefaultsKey), "small")
        XCTAssertEqual(defaults.string(forKey: hotkeyChoiceDefaultsKey), "option_space")
        XCTAssertEqual(defaults.string(forKey: onboardingCompletedAppPathDefaultsKey), appURL.path)
    }

    func testRememberCompletedOnboardingForCurrentInstallStoresCurrentPath() {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }

        let appURL = URL(fileURLWithPath: "/Users/tester/Applications/HoldToTalk.app", isDirectory: true)
        defaults.set(true, forKey: onboardingNeedsResumeAfterAppMoveDefaultsKey)
        rememberCompletedOnboardingForCurrentInstall(defaults: defaults, currentAppURL: appURL)

        XCTAssertTrue(defaults.bool(forKey: onboardingCompleteDefaultsKey))
        XCTAssertFalse(defaults.bool(forKey: onboardingNeedsResumeAfterAppMoveDefaultsKey))
        XCTAssertEqual(defaults.string(forKey: onboardingCompletedAppPathDefaultsKey), appURL.path)
    }

    func testCompletedOnboardingRequiresLocalModelOnlyForLocalTranscription() {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }

        XCTAssertTrue(completedOnboardingRequiresLocalModel(defaults: defaults))

        defaults.set(TranscriptionProvider.openAI.rawValue, forKey: transcriptionProviderDefaultsKey)
        XCTAssertFalse(completedOnboardingRequiresLocalModel(defaults: defaults))

        defaults.set("unknown", forKey: transcriptionProviderDefaultsKey)
        XCTAssertTrue(completedOnboardingRequiresLocalModel(defaults: defaults))
    }

    func testResetPersistedAppStateClearsDefaultsAndAppDataButKeepsAppSupportRoot() throws {
        let fileManager = FileManager.default
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }

        let home = root.appendingPathComponent("Home", isDirectory: true)
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: onboardingCompleteDefaultsKey)
        defaults.set(3, forKey: onboardingStepDefaultsKey)
        defaults.set("base", forKey: whisperModelDefaultsKey)

        let appSupport = holdToTalkApplicationSupportDirectory(homeDirectory: home)
        let appSupportChild = appSupport.appendingPathComponent("models/cache.bin")
        let logFile = appSupport.appendingPathComponent("debug.log")
        let unrelatedLibraryFile = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent("keep.txt")

        let cacheDirectories = holdToTalkCacheDirectories(
            homeDirectory: home,
            bundleIdentifier: suiteName
        )

        try fileManager.createDirectory(
            at: appSupportChild.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "model".write(to: appSupportChild, atomically: true, encoding: .utf8)
        try "log".write(to: logFile, atomically: true, encoding: .utf8)
        try fileManager.createDirectory(
            at: unrelatedLibraryFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "keep".write(to: unrelatedLibraryFile, atomically: true, encoding: .utf8)

        for cacheDirectory in cacheDirectories {
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try "cache".write(
                to: cacheDirectory.appendingPathComponent("artifact.txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        resetPersistedAppStateForFreshOnboarding(
            defaults: defaults,
            bundleIdentifier: suiteName,
            fileManager: fileManager,
            homeDirectory: home
        )

        XCTAssertFalse(defaults.bool(forKey: onboardingCompleteDefaultsKey))
        XCTAssertNil(defaults.object(forKey: onboardingStepDefaultsKey))
        XCTAssertNil(defaults.object(forKey: whisperModelDefaultsKey))

        XCTAssertTrue(fileManager.fileExists(atPath: appSupport.path))
        let appSupportContents = try fileManager.contentsOfDirectory(
            at: appSupport,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(appSupportContents.isEmpty)

        for cacheDirectory in cacheDirectories {
            XCTAssertFalse(fileManager.fileExists(atPath: cacheDirectory.path))
        }

        XCTAssertTrue(fileManager.fileExists(atPath: unrelatedLibraryFile.path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let fileManager = FileManager.default
        let url = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
