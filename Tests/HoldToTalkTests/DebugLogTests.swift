import XCTest
@testable import HoldToTalk

final class DebugLogTests: XCTestCase {
    func testDiagnosticLogRedactionSummaryRedactsTranscriptContent() {
        let summary = diagnosticLogRedactionSummary(for: "alpha beta gamma")

        XCTAssertEqual(summary, "<redacted 16 chars, 3 words>")
        XCTAssertFalse(summary.contains("alpha"))
        XCTAssertFalse(summary.contains("beta"))
        XCTAssertFalse(summary.contains("gamma"))
    }

    func testDiagnosticLogRedactionSummaryHandlesEmptyContent() {
        XCTAssertEqual(diagnosticLogRedactionSummary(for: " \n\t "), "<redacted empty>")
    }

    func testSecureInputFailureReportExposesUserFacingError() {
        let report = TextInserter.InsertReport(
            success: false,
            confirmed: false,
            method: nil,
            attempts: ["secureInput=on", "blocked=secureInput"],
            failureReason: .secureInput
        )

        XCTAssertEqual(
            report.userFacingError,
            "Secure text input is active. Dictation is unavailable in password and other protected fields."
        )
        XCTAssertTrue(report.summary.contains("Secure text input is active."))
    }

    func testShellTargetFailureReportExposesUserFacingError() {
        let report = TextInserter.InsertReport(
            success: false,
            confirmed: false,
            method: nil,
            attempts: ["app=com.apple.Terminal", "blocked=shellTarget"],
            failureReason: .shellTargetNotConfirmed
        )

        XCTAssertEqual(
            report.userFacingError,
            "Dictation into terminal apps requires confirmation before text is inserted."
        )
        XCTAssertTrue(report.summary.contains("terminal apps requires confirmation"))
    }

    func testTerminalBundleIDsRequireConfirmation() {
        XCTAssertTrue(TextInserter.requiresShellTargetConfirmation(bundleID: "com.apple.Terminal"))
        XCTAssertTrue(TextInserter.requiresShellTargetConfirmation(bundleID: "com.googlecode.iterm2"))
        XCTAssertFalse(TextInserter.requiresShellTargetConfirmation(bundleID: "com.apple.TextEdit"))
        XCTAssertFalse(TextInserter.requiresShellTargetConfirmation(bundleID: nil))
    }

    func testSuccessfulInsertionReportDoesNotExposeUserFacingError() {
        let report = TextInserter.InsertReport(
            success: true,
            confirmed: true,
            method: "unicodeChunked",
            attempts: ["pass1:unicodeChunked=tentative"],
            failureReason: nil
        )

        XCTAssertNil(report.userFacingError)
        XCTAssertEqual(report.summary, "Inserted via unicodeChunked.")
    }
}
