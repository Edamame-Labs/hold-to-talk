import XCTest
@testable import HoldToTalk

final class SystemCompatibilityTests: XCTestCase {
    func testParseVersionStringSupportsShortAndFullForms() {
        XCTAssertTrue(
            versionsMatch(
                SystemRequirements.parse(versionString: "15"),
                OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
            )
        )
        XCTAssertTrue(
            versionsMatch(
                SystemRequirements.parse(versionString: "15.2"),
                OperatingSystemVersion(majorVersion: 15, minorVersion: 2, patchVersion: 0)
            )
        )
        XCTAssertTrue(
            versionsMatch(
                SystemRequirements.parse(versionString: "15.2.1"),
                OperatingSystemVersion(majorVersion: 15, minorVersion: 2, patchVersion: 1)
            )
        )
        XCTAssertNil(SystemRequirements.parse(versionString: "fifteen"))
    }

    func testMinimumMacOSVersionReadsFromBundleInfoPlist() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundleURL = root.appendingPathComponent("Fixture.bundle", isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: contentsURL, withIntermediateDirectories: true)

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>com.holdtotalk.tests.fixture</string>
            <key>CFBundleName</key>
            <string>Fixture</string>
            <key>LSMinimumSystemVersion</key>
            <string>15.3</string>
        </dict>
        </plist>
        """
        try plist.write(
            to: contentsURL.appendingPathComponent("Info.plist"),
            atomically: true,
            encoding: .utf8
        )

        let bundle = try XCTUnwrap(Bundle(url: bundleURL))
        XCTAssertTrue(
            versionsMatch(
                SystemRequirements.minimumMacOSVersion(from: bundle),
                OperatingSystemVersion(majorVersion: 15, minorVersion: 3, patchVersion: 0)
            )
        )
    }

    func testCompatibilityFlagsOlderMacOSAsUnsupported() {
        let requirements = SystemRequirements(
            minimumMacOSVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        )
        let compatibility = SystemCompatibility(
            requirements: requirements,
            currentMacOSVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 7, patchVersion: 0),
            isAppleSiliconMac: true
        )

        XCTAssertFalse(compatibility.isSupported)
        XCTAssertFalse(compatibility.meetsMinimumMacOS)
        XCTAssertEqual(compatibility.requirements.summaryText, "macOS 15+ and Apple Silicon")
        XCTAssertEqual(
            compatibility.unsupportedInstallMessage,
            "Hold to Talk requires macOS 15+ and Apple Silicon. This Mac is running macOS 14.7."
        )
    }

    func testCompatibilityRejectsNonAppleSiliconWhenMacOSIsSupported() {
        let requirements = SystemRequirements(
            minimumMacOSVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        )
        let compatibility = SystemCompatibility(
            requirements: requirements,
            currentMacOSVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 1, patchVersion: 0),
            isAppleSiliconMac: false
        )

        XCTAssertFalse(compatibility.isSupported)
        XCTAssertTrue(compatibility.meetsMinimumMacOS)
        XCTAssertFalse(compatibility.meetsArchitecture)
        XCTAssertEqual(compatibility.requirements.summaryText, "macOS 15+ and Apple Silicon")
        XCTAssertEqual(
            compatibility.statusDetailText,
            "This Mac is running macOS 15.1 and does not meet the Apple Silicon requirement."
        )
    }

    private func versionsMatch(
        _ lhs: OperatingSystemVersion?,
        _ rhs: OperatingSystemVersion
    ) -> Bool {
        guard let lhs else { return false }
        return lhs.majorVersion == rhs.majorVersion &&
            lhs.minorVersion == rhs.minorVersion &&
            lhs.patchVersion == rhs.patchVersion
    }
}
