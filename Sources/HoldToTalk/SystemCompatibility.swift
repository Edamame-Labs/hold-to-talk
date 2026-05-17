import Darwin
import Foundation

struct SystemRequirements: Equatable {
    let minimumMacOSVersion: OperatingSystemVersion
    let requiresAppleSilicon: Bool

    init(
        minimumMacOSVersion: OperatingSystemVersion,
        requiresAppleSilicon: Bool = true
    ) {
        self.minimumMacOSVersion = minimumMacOSVersion
        self.requiresAppleSilicon = requiresAppleSilicon
    }

    init(bundle: Bundle = .main, requiresAppleSilicon: Bool = true) {
        self.minimumMacOSVersion = Self.minimumMacOSVersion(from: bundle)
            ?? OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        self.requiresAppleSilicon = requiresAppleSilicon
    }

    static func minimumMacOSVersion(from bundle: Bundle) -> OperatingSystemVersion? {
        guard let versionString = bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String else {
            return nil
        }
        return parse(versionString: versionString)
    }

    static func parse(versionString: String) -> OperatingSystemVersion? {
        let parts = versionString.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }

        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }

        return OperatingSystemVersion(
            majorVersion: numbers[0],
            minorVersion: numbers.count > 1 ? numbers[1] : 0,
            patchVersion: numbers.count > 2 ? numbers[2] : 0
        )
    }

    var minimumMacOSDisplayName: String {
        displayVersion(minimumMacOSVersion)
    }

    var minimumMacOSRequirementName: String {
        displayRequirement(minimumMacOSVersion)
    }

    var summaryText: String {
        var parts = ["macOS \(minimumMacOSRequirementName)"]
        if requiresAppleSilicon {
            parts.append("Apple Silicon")
        }
        return parts.joined(separator: " and ")
    }

    static func == (lhs: SystemRequirements, rhs: SystemRequirements) -> Bool {
        lhs.minimumMacOSVersion.majorVersion == rhs.minimumMacOSVersion.majorVersion &&
        lhs.minimumMacOSVersion.minorVersion == rhs.minimumMacOSVersion.minorVersion &&
        lhs.minimumMacOSVersion.patchVersion == rhs.minimumMacOSVersion.patchVersion &&
        lhs.requiresAppleSilicon == rhs.requiresAppleSilicon
    }
}

struct SystemCompatibility: Equatable {
    let requirements: SystemRequirements
    let currentMacOSVersion: OperatingSystemVersion
    let isAppleSiliconMac: Bool

    init(
        requirements: SystemRequirements,
        currentMacOSVersion: OperatingSystemVersion,
        isAppleSiliconMac: Bool
    ) {
        self.requirements = requirements
        self.currentMacOSVersion = currentMacOSVersion
        self.isAppleSiliconMac = isAppleSiliconMac
    }

    static func current(
        bundle: Bundle = .main,
        currentMacOSVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        isAppleSiliconMac: Bool = systemIsAppleSilicon
    ) -> SystemCompatibility {
        SystemCompatibility(
            requirements: SystemRequirements(bundle: bundle),
            currentMacOSVersion: currentMacOSVersion,
            isAppleSiliconMac: isAppleSiliconMac
        )
    }

    var currentMacOSDisplayName: String {
        displayVersion(currentMacOSVersion)
    }

    var meetsMinimumMacOS: Bool {
        compareVersions(currentMacOSVersion, requirements.minimumMacOSVersion) != .orderedAscending
    }

    var meetsArchitecture: Bool {
        !requirements.requiresAppleSilicon || isAppleSiliconMac
    }

    var isSupported: Bool {
        meetsMinimumMacOS && meetsArchitecture
    }

    var statusText: String {
        isSupported ? "Compatible on this Mac" : "Not compatible on this Mac"
    }

    var statusDetailText: String {
        if isSupported {
            return "This Mac is running macOS \(currentMacOSDisplayName) and meets the system requirements."
        }

        var issues: [String] = []
        if !meetsMinimumMacOS {
            issues.append("macOS \(requirements.minimumMacOSRequirementName)")
        }
        if !meetsArchitecture {
            issues.append("Apple Silicon")
        }

        return "This Mac is running macOS \(currentMacOSDisplayName) and does not meet the \(issues.joined(separator: " and ")) requirement."
    }

    var installPromptText: String {
        """
        Requires \(requirements.summaryText).
        This Mac: macOS \(currentMacOSDisplayName) \(isSupported ? "supported" : "not supported").

        Hold to Talk works best when installed in /Applications. Permissions and Launch at Login require it.

        Would you like to move it now?
        """
    }

    var unsupportedInstallMessage: String {
        "Hold to Talk requires \(requirements.summaryText). This Mac is running macOS \(currentMacOSDisplayName)."
    }

    private static let systemIsAppleSilicon: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 {
            return value == 1
        }

        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }()

    static func == (lhs: SystemCompatibility, rhs: SystemCompatibility) -> Bool {
        lhs.requirements == rhs.requirements &&
        lhs.currentMacOSVersion.majorVersion == rhs.currentMacOSVersion.majorVersion &&
        lhs.currentMacOSVersion.minorVersion == rhs.currentMacOSVersion.minorVersion &&
        lhs.currentMacOSVersion.patchVersion == rhs.currentMacOSVersion.patchVersion &&
        lhs.isAppleSiliconMac == rhs.isAppleSiliconMac
    }
}

private func compareVersions(
    _ lhs: OperatingSystemVersion,
    _ rhs: OperatingSystemVersion
) -> ComparisonResult {
    if lhs.majorVersion != rhs.majorVersion {
        return lhs.majorVersion < rhs.majorVersion ? .orderedAscending : .orderedDescending
    }
    if lhs.minorVersion != rhs.minorVersion {
        return lhs.minorVersion < rhs.minorVersion ? .orderedAscending : .orderedDescending
    }
    if lhs.patchVersion != rhs.patchVersion {
        return lhs.patchVersion < rhs.patchVersion ? .orderedAscending : .orderedDescending
    }
    return .orderedSame
}

private func displayVersion(_ version: OperatingSystemVersion) -> String {
    if version.patchVersion > 0 {
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
    if version.minorVersion > 0 {
        return "\(version.majorVersion).\(version.minorVersion)"
    }
    return "\(version.majorVersion)"
}

private func displayRequirement(_ version: OperatingSystemVersion) -> String {
    "\(displayVersion(version))+"
}
