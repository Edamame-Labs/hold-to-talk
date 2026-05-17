import XCTest
@testable import HoldToTalk

final class CloudSecurityTests: XCTestCase {
    func testCloudBaseURLRequiresHTTPS() {
        XCTAssertThrowsError(try normalizedCloudBaseURL("http://api.example.com/v1")) { error in
            XCTAssertEqual(error.localizedDescription, "Refusing to send API request to a non-HTTPS URL. Check your base URL in Settings.")
            XCTAssertFalse(error.localizedDescription.contains("api.example.com"))
        }
    }

    func testCloudBaseURLRejectsEmbeddedCredentials() {
        XCTAssertThrowsError(try normalizedCloudBaseURL("https://user:secret@api.example.com/v1")) { error in
            XCTAssertEqual(error.localizedDescription, "Cloud base URL must not include usernames or passwords.")
            XCTAssertFalse(error.localizedDescription.contains("secret"))
        }
    }

    func testCloudBaseURLRejectsQueryAndFragment() {
        XCTAssertThrowsError(try normalizedCloudBaseURL("https://api.example.com/v1?token=secret#frag")) { error in
            XCTAssertEqual(error.localizedDescription, "Cloud base URL must not include query strings or fragments.")
            XCTAssertFalse(error.localizedDescription.contains("secret"))
        }
    }

    func testCloudBaseURLNormalizesTrailingSlashAndPreservesPath() throws {
        let url = try normalizedCloudBaseURL("  https://proxy.example.com/openai/v1/  ")

        XCTAssertEqual(url.absoluteString, "https://proxy.example.com/openai/v1")
        XCTAssertEqual(
            url.appendingPathComponent("audio/transcriptions").absoluteString,
            "https://proxy.example.com/openai/v1/audio/transcriptions"
        )
    }

    func testCloudErrorDescriptionsDoNotExposeProviderBody() {
        let transcriptionError = CloudTranscriberError.apiError(statusCode: 400).localizedDescription
        let cleanupError = CloudCleanupError.apiError(provider: "OpenAI", statusCode: 400).localizedDescription

        XCTAssertEqual(transcriptionError, "Transcription API error (400). Check your cloud settings.")
        XCTAssertEqual(cleanupError, "OpenAI cleanup error (400). Check your cloud settings.")
        XCTAssertFalse(transcriptionError.contains("transcript"))
        XCTAssertFalse(cleanupError.contains("transcript"))
    }
}
