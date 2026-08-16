import XCTest
@testable import HoldToTalk

final class OnboardingSetupTests: XCTestCase {
    func testLocalModelAutoDownloadStartsOnlyWhenNeeded() {
        XCTAssertTrue(
            shouldAutomaticallyDownloadLocalModel(
                provider: .local,
                isDownloaded: false,
                isDownloading: false
            )
        )
        XCTAssertFalse(
            shouldAutomaticallyDownloadLocalModel(
                provider: .local,
                isDownloaded: true,
                isDownloading: false
            )
        )
        XCTAssertFalse(
            shouldAutomaticallyDownloadLocalModel(
                provider: .local,
                isDownloaded: false,
                isDownloading: true
            )
        )
        XCTAssertFalse(
            shouldAutomaticallyDownloadLocalModel(
                provider: .openAI,
                isDownloaded: false,
                isDownloading: false
            )
        )
    }

    func testOnboardingReadinessMatchesSelectedDictationProvider() {
        XCTAssertTrue(
            onboardingDictationIsReady(
                provider: .local,
                localModelIsDownloaded: true,
                hasCloudKey: false
            )
        )
        XCTAssertFalse(
            onboardingDictationIsReady(
                provider: .local,
                localModelIsDownloaded: false,
                hasCloudKey: true
            )
        )
        XCTAssertTrue(
            onboardingDictationIsReady(
                provider: .openAI,
                localModelIsDownloaded: false,
                hasCloudKey: true
            )
        )
        XCTAssertFalse(
            onboardingDictationIsReady(
                provider: .openAI,
                localModelIsDownloaded: true,
                hasCloudKey: false
            )
        )
    }
}
