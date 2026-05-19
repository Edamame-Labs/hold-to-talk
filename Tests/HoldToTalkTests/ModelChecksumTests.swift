import XCTest
@testable import HoldToTalk

final class ModelChecksumTests: XCTestCase {
    func testParakeetModelArchiveChecksumIsPinned() {
        XCTAssertEqual(SpeechModelInfo.expectedSHA256.count, 64)
        XCTAssertTrue(SpeechModelInfo.expectedSHA256.allSatisfy(\.isHexDigit))
    }

    func testModelChecksumVerifierAcceptsMatchingDigest() throws {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try Data("hello".utf8).write(to: fileURL)

        try ModelManager.verifyChecksum(
            of: fileURL,
            expected: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        )
    }

    func testModelChecksumVerifierRejectsMismatchedDigest() throws {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try Data("hello".utf8).write(to: fileURL)

        XCTAssertThrowsError(
            try ModelManager.verifyChecksum(
                of: fileURL,
                expected: "0000000000000000000000000000000000000000000000000000000000000000"
            )
        ) { error in
            guard case ModelExtractionError.checksumMismatch = error else {
                return XCTFail("Expected checksum mismatch, got \(error)")
            }
        }
    }

    func testModelArchiveValidationAcceptsExpectedRoot() throws {
        let modelDirectory = temporaryFileURL()
        let destinations = try ModelManager.validatedModelArchiveDestinations(
            for: [
                "\(SpeechModelInfo.modelDirectoryName)/",
                "\(SpeechModelInfo.modelDirectoryName)/tokens.txt",
                "\(SpeechModelInfo.modelDirectoryName)/encoder.int8.onnx",
            ],
            modelDirectory: modelDirectory
        )

        XCTAssertEqual(destinations.count, 2)
        XCTAssertTrue(destinations.allSatisfy { $0.path.hasPrefix(modelDirectory.path) })
    }

    func testModelArchiveValidationRejectsPathTraversal() {
        let modelDirectory = temporaryFileURL()

        XCTAssertThrowsError(
            try ModelManager.validatedModelArchiveDestinations(
                for: ["\(SpeechModelInfo.modelDirectoryName)/../../.ssh/authorized_keys"],
                modelDirectory: modelDirectory
            )
        ) { error in
            guard case ModelExtractionError.unsafeArchivePath = error else {
                return XCTFail("Expected unsafe archive path, got \(error)")
            }
        }
    }

    func testModelArchiveValidationRejectsUnexpectedRoot() {
        let modelDirectory = temporaryFileURL()

        XCTAssertThrowsError(
            try ModelManager.validatedModelArchiveDestinations(
                for: ["other-root/tokens.txt"],
                modelDirectory: modelDirectory
            )
        ) { error in
            guard case ModelExtractionError.unexpectedArchiveRoot = error else {
                return XCTFail("Expected unexpected archive root, got \(error)")
            }
        }
    }

    func testModelArchiveValidationRejectsSymlinkEntries() {
        XCTAssertThrowsError(
            try ModelManager.validateModelArchiveEntryTypes([
                "lrwxr-xr-x  0 user group 0 Jan 1 00:00 \(SpeechModelInfo.modelDirectoryName)/encoder.int8.onnx -> /tmp/target",
            ])
        ) { error in
            guard case ModelExtractionError.unsafeArchivePath = error else {
                return XCTFail("Expected unsafe archive path, got \(error)")
            }
        }
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
    }
}
