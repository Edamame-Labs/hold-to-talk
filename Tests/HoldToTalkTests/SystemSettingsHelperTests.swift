import XCTest
@testable import HoldToTalk

final class SystemSettingsHelperTests: XCTestCase {
    func testAppHasStableCodeIdentityReadsInfoPlistFlag() {
        XCTAssertTrue(appHasStableCodeIdentity(infoDictionary: [stableCodeIdentityInfoPlistKey: true]))
        XCTAssertFalse(appHasStableCodeIdentity(infoDictionary: [stableCodeIdentityInfoPlistKey: false]))
    }

    func testAppHasStableCodeIdentityDefaultsToFalseWhenMissing() {
        XCTAssertFalse(appHasStableCodeIdentity(infoDictionary: [:]))
    }

    func testCheckPostEventAccessAcceptsAccessibilityTrustWhenPreflightIsStale() {
        var didPostTestEvent = false

        XCTAssertTrue(
            checkPostEventAccess(
                preflight: { false },
                accessibilityTrusted: { true },
                postTestEvent: { didPostTestEvent = true }
            )
        )
        XCTAssertFalse(didPostTestEvent)
    }

    func testCheckPostEventAccessRetriesSignalsAfterTestEvent() {
        var preflightCalls = 0
        var didPostTestEvent = false

        XCTAssertTrue(
            checkPostEventAccess(
                preflight: {
                    preflightCalls += 1
                    return preflightCalls > 1
                },
                accessibilityTrusted: { false },
                postTestEvent: { didPostTestEvent = true }
            )
        )
        XCTAssertTrue(didPostTestEvent)
    }

    func testRequestPostEventAccessOpensSettingsOnFirstAttemptWhenSystemShowsNoDialog() {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }

        var openedAnchor: String?
        var requestCallCount = 0

        let result = requestPostEventAccess(
            defaults: defaults,
            preflight: { false },
            requestAccess: {
                requestCallCount += 1
                return false
            },
            settingsOpener: { openedAnchor = $0 }
        )

        XCTAssertEqual(result, .openedSettings)
        XCTAssertEqual(requestCallCount, 1)
        XCTAssertEqual(openedAnchor, "Privacy_Accessibility")
        XCTAssertTrue(defaults.bool(forKey: postEventPromptedDefaultsKey))
    }

    func testRequestPostEventAccessDoesNotOpenSettingsWhenAccessIsGrantedImmediately() {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }

        var didOpenSettings = false

        let result = requestPostEventAccess(
            defaults: defaults,
            preflight: { true },
            requestAccess: {
                XCTFail("requestAccess should not run when permission is already granted")
                return true
            },
            settingsOpener: { _ in didOpenSettings = true }
        )

        XCTAssertEqual(result, .granted)
        XCTAssertFalse(didOpenSettings)
        XCTAssertFalse(defaults.bool(forKey: postEventPromptedDefaultsKey))
    }

    func testSecondAttemptStillOpensSettingsWithoutRetryingRequestAPI() {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removePersistentDomain(forName: #function) }
        defaults.set(true, forKey: postEventPromptedDefaultsKey)

        var openedAnchor: String?

        let result = requestPostEventAccess(
            defaults: defaults,
            preflight: { false },
            requestAccess: {
                XCTFail("requestAccess should not run after the first attempt")
                return false
            },
            settingsOpener: { openedAnchor = $0 }
        )

        XCTAssertEqual(result, .openedSettings)
        XCTAssertEqual(openedAnchor, "Privacy_Accessibility")
    }
}
